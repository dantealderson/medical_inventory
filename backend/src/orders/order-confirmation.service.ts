import { HttpStatus, Injectable } from '@nestjs/common';
import { type Notification, NotificationType, OrderStatus, type Prisma } from '@prisma/client';

import {
  AllocationService,
  type AllocationRequest,
  type PreviewPortion,
} from '../allocation/allocation.service';
import type { PlanRequest } from '../allocation/fefo-plan';
import { AuditService } from '../audit/audit.service';
import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import { billedAmount, formatMoney, sumMoney } from '../common/money';
import { boxesToUnits } from '../common/units';
import { texts } from '../notifications/notification-texts';
import { NotificationsService } from '../notifications/notifications.service';
import { PrismaService } from '../prisma/prisma.service';
import { ORDER_TX_OPTIONS } from '../prisma/transaction';
import type { ConfirmOrderDto, LineEditDto } from './dto/confirm-order.dto';
import { lockOrder } from './order-lock';
import { assertTransition } from './order-state';
import { loadOrderView, type OrderView } from './order-views';

export interface AllocationPreviewLineView {
  orderLineId: string;
  itemId: string;
  qtyBoxesApproved: number;
  qtyUnitsApproved: number;
  qtyUnitsAllocated: number;
  shortByUnits: number;
  /** What this line would bill if confirmed now: price × allocated units ÷ unitsPerBox, 2 dp. */
  projectedLineTotal: string;
  /** Earliest expiry first, exactly as confirm would take them. */
  allocations: PreviewPortion[];
}

export interface AllocationPreviewView {
  orderId: string;
  /** The business-date cutoff used. Only batches expiring strictly after it are eligible. */
  minExpiryExclusive: string;
  lines: AllocationPreviewLineView[];
  projectedTotalAmount: string;
}

/** The columns that approval and billing read, one row per line. */
const LINE_FIELDS = {
  id: true,
  itemId: true,
  qtyBoxesRequested: true,
  unitsPerBoxSnapshot: true,
  pricePerBoxSnapshot: true,
} satisfies Prisma.OrderLineSelect;

interface LineForApproval {
  id: string;
  itemId: string;
  qtyBoxesRequested: number;
  unitsPerBoxSnapshot: number;
  pricePerBoxSnapshot: Prisma.Decimal;
}

interface ApprovedLine extends LineForApproval {
  qtyBoxesApproved: number;
  qtyUnitsApproved: number;
}

@Injectable()
export class OrderConfirmationService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly allocation: AllocationService,
    private readonly audit: AuditService,
    private readonly notifications: NotificationsService,
  ) {}

  /**
   * What confirm would do right now with these edits. It uses the same
   * validation, the same candidate query and the same planner, but takes no
   * lock and writes nothing. It is advisory: stock can move between this
   * answer and the confirm, which re-plans under the batch locks.
   * It does not refuse a plan that ships nothing. Showing the admin all
   * zeros is the point, and confirm then refuses.
   */
  async preview(orderId: string, dto: ConfirmOrderDto): Promise<AllocationPreviewView> {
    const minExpiryExclusive = await this.allocation.cutoffFor();

    const order = await this.prisma.order.findUnique({
      where: { id: orderId },
      select: { status: true, lines: { orderBy: { position: 'asc' }, select: LINE_FIELDS } },
    });
    if (!order) {
      throw new AppException(HttpStatus.NOT_FOUND, 'ORDER_NOT_FOUND', ERROR_CODES.ORDER_NOT_FOUND);
    }
    // Only a PLACED order has a confirmation to preview. Any other status
    // gets the same 409 that confirm would give.
    assertTransition(order.status, OrderStatus.CONFIRMED);

    const approved = approveLines(order.lines, dto.lines);
    const requests: PlanRequest[] = approved
      .filter((l) => l.qtyUnitsApproved > 0)
      .map((l) => ({ key: l.id, itemId: l.itemId, qtyUnits: l.qtyUnitsApproved }));
    const planned =
      requests.length > 0
        ? await this.allocation.preview(this.prisma, requests, minExpiryExclusive)
        : [];
    const planByLine = new Map(planned.map((p) => [p.key, p]));

    const lines: AllocationPreviewLineView[] = [];
    const totals: Prisma.Decimal[] = [];
    for (const l of approved) {
      const plan = planByLine.get(l.id);
      const allocated = plan?.qtyUnitsAllocated ?? 0;
      const lineTotal = billedAmount(l.pricePerBoxSnapshot, allocated, l.unitsPerBoxSnapshot);
      totals.push(lineTotal);
      lines.push({
        orderLineId: l.id,
        itemId: l.itemId,
        qtyBoxesApproved: l.qtyBoxesApproved,
        qtyUnitsApproved: l.qtyUnitsApproved,
        qtyUnitsAllocated: allocated,
        shortByUnits: l.qtyUnitsApproved - allocated,
        projectedLineTotal: formatMoney(lineTotal),
        allocations: plan?.allocated ?? [],
      });
    }

    return {
      orderId,
      minExpiryExclusive,
      lines,
      projectedTotalAmount: formatMoney(sumMoney(totals)),
    };
  }

  async confirm(adminId: string, orderId: string, dto: ConfirmOrderDto): Promise<OrderView> {
    // D5: the cutoff comes from settings, and SettingsService only has the
    // root client. Read inside the transaction, it would take a second pool
    // connection while this one holds row locks.
    const minExpiryExclusive = await this.allocation.cutoffFor();

    let created: Notification[] = [];
    const confirmed = await this.prisma.$transaction(async (tx) => {
      // D1: the order row comes before anything else. A double-clicked
      // confirm queues here. Under READ COMMITTED the second request then
      // re-reads the committed row, sees CONFIRMED and gets a 409. Without
      // this it would allocate the order a second time, and the ledger would
      // agree.
      const order = await lockOrder(tx, orderId);
      assertTransition(order.status, OrderStatus.CONFIRMED);

      const lines: LineForApproval[] = await tx.orderLine.findMany({
        where: { orderId },
        orderBy: { position: 'asc' },
        select: LINE_FIELDS,
      });
      const approved = approveLines(lines, dto.lines);

      // A line approved at 0 is dropped rather than allocated. It sends no
      // request, so no batch is locked or touched for it.
      const requests: AllocationRequest[] = approved
        .filter((l) => l.qtyUnitsApproved > 0)
        .map((l) => ({ orderLineId: l.id, itemId: l.itemId, qtyUnits: l.qtyUnitsApproved }));
      // D2: allocate writes the decrement, the negative ORDER_OUT, the
      // allocation row and qtyUnitsFulfilled together. It never throws on a
      // shortage; a short line comes back with shortBy > 0.
      const results =
        requests.length > 0
          ? await this.allocation.allocate(tx, requests, {
              orderId,
              actorUserId: adminId,
              minExpiryExclusive,
            })
          : [];

      // §7.4: a confirmation that ships nothing is not a confirmation.
      // Throwing inside the callback rolls back everything above, so the
      // order stays PLACED with nothing reserved, and the admin cancels it.
      if (results.every((r) => r.qtyUnitsAllocated === 0)) {
        throw new AppException(
          HttpStatus.CONFLICT,
          'ORDER_NOTHING_TO_FULFIL',
          ERROR_CODES.ORDER_NOTHING_TO_FULFIL,
        );
      }
      const fulfilled = new Map(results.map((r) => [r.orderLineId, r.qtyUnitsAllocated]));

      const lineTotals: Prisma.Decimal[] = [];
      for (const l of approved) {
        // D8: bill what was fulfilled, not what was asked for. The driver
        // collects this total in cash, and charging a clinic for stock that
        // never arrived is how a supplier relationship ends.
        const lineTotal = billedAmount(
          l.pricePerBoxSnapshot,
          fulfilled.get(l.id) ?? 0,
          l.unitsPerBoxSnapshot,
        );
        lineTotals.push(lineTotal);
        // One write per line, after the batch locks, keeping D1's lock order.
        // The approval is stored beside the request, never over it (D7).
        // order_lines_quantities re-checks fulfilled ≤ approved on this final
        // row, so an allocation that over-served an edited line fails here
        // instead of shipping.
        await tx.orderLine.update({
          where: { id: l.id },
          data: {
            qtyBoxesApproved: l.qtyBoxesApproved,
            qtyUnitsApproved: l.qtyUnitsApproved,
            lineTotal,
          },
        });
      }
      // Always recomputed as Σ lineTotal, never on its own. Otherwise the
      // cash total and the lines the driver reads out can disagree by a
      // rounding cent.
      const totalAmount = sumMoney(lineTotals);

      await tx.order.update({
        where: { id: orderId },
        data: { status: OrderStatus.CONFIRMED, confirmedAt: new Date(), totalAmount },
      });

      // D9: recorded with tx, so the entry commits or rolls back with the
      // decision. Money goes in as a string: redact() would rebuild a
      // Prisma.Decimal as {s, e, d}.
      await this.audit.record(
        {
          actorUserId: adminId,
          action: 'ORDER_CONFIRMED',
          entityType: 'order',
          entityId: orderId,
          before: {
            lines: lines.map((l) => ({ orderLineId: l.id, qtyBoxesRequested: l.qtyBoxesRequested })),
          },
          after: {
            lines: approved.map((l) => ({
              orderLineId: l.id,
              qtyBoxesApproved: l.qtyBoxesApproved,
              qtyUnitsFulfilled: fulfilled.get(l.id) ?? 0,
            })),
            totalAmount: formatMoney(totalAmount),
          },
        },
        tx,
      );

      const view = await loadOrderView(tx, orderId);
      created = [
        await this.notifications.create(tx, {
          recipientUserId: order.clientId,
          type: NotificationType.ORDER_CONFIRMED,
          ...texts.orderConfirmed(view.lines.some((l) => l.shortByUnits > 0)),
          payload: { orderId },
        }),
      ];
      return view;
    }, ORDER_TX_OPTIONS);
    await this.notifications.push(created);
    return confirmed;
  }
}

/**
 * Applies the admin's edits in position order. Every line gets an approval,
 * and unedited lines are approved as requested, because a NULL approval
 * means "not yet confirmed" (D7).
 */
function approveLines(lines: LineForApproval[], edits: LineEditDto[] | undefined): ApprovedLine[] {
  const requestedBoxes = new Map(lines.map((l) => [l.id, l.qtyBoxesRequested]));
  const approvedBoxes = new Map<string, number>();

  for (const edit of edits ?? []) {
    const requested = requestedBoxes.get(edit.orderLineId);
    // Three ways an edit fails to be an answer about THIS order:
    // - the id is not one of its lines: another order's line, or a stale
    //   screen;
    // - it is a second edit for the same line: two answers, and picking one
    //   is a guess;
    // - it is more than requested: §7.4 lets the supplier reduce, never
    //   increase, or the clinic is billed for boxes it never asked for.
    if (
      requested === undefined ||
      approvedBoxes.has(edit.orderLineId) ||
      edit.qtyBoxes > requested
    ) {
      throw new AppException(
        HttpStatus.BAD_REQUEST,
        'ORDER_EDIT_INVALID',
        ERROR_CODES.ORDER_EDIT_INVALID,
      );
    }
    approvedBoxes.set(edit.orderLineId, edit.qtyBoxes);
  }

  return lines.map((l) => {
    const boxes = approvedBoxes.get(l.id) ?? l.qtyBoxesRequested;
    return {
      ...l,
      qtyBoxesApproved: boxes,
      qtyUnitsApproved: boxesToUnits(boxes, l.unitsPerBoxSnapshot),
    };
  });
}
