import { HttpStatus } from '@nestjs/common';
import type { CancelDisposition, OrderStatus, Prisma } from '@prisma/client';

import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import { formatMoney } from '../common/money';

export interface OrderClientView {
  id: string;
  username: string;
  clinicName: string | null;
}

export interface OrderAllocationView {
  batchId: string;
  batchNumber: string;
  /** 'YYYY-MM-DD'. */
  expiryDate: string;
  qtyUnits: number;
  /** True once the allocation was released by a cancellation. */
  released: boolean;
}

export interface OrderLineView {
  id: string;
  itemId: string;
  position: number;
  item: {
    id: string;
    nameAr: string | null;
    nameEn: string | null;
    unitLabelAr: string;
    imageUrl: string | null;
  };
  unitsPerBoxSnapshot: number;
  pricePerBoxSnapshot: string;
  lineTotal: string;
  qtyBoxesRequested: number;
  qtyUnitsRequested: number;
  qtyBoxesApproved: number | null;
  qtyUnitsApproved: number | null;
  qtyUnitsFulfilled: number;
  /** approved < requested (supplier adjusted). false until confirmed. */
  adjustedBySupplier: boolean;
  /** approved − fulfilled once confirmed, else 0 (warehouse short). */
  shortByUnits: number;
  /** Ordered by expiryDate ASC, batchNumber ASC. */
  allocations: OrderAllocationView[];
}

export interface OrderView {
  id: string;
  status: OrderStatus;
  client: OrderClientView;
  placedAt: string;
  confirmedAt: string | null;
  dispatchedAt: string | null;
  deliveredAt: string | null;
  cancelledAt: string | null;
  cancelReason: string | null;
  cancelDisposition: CancelDisposition | null;
  totalAmount: string;
  addressSnapshot: string | null;
  phoneSnapshot: string | null;
  note: string | null;
  /** Ordered by position. */
  lines: OrderLineView[];
}

export interface OrderSummaryView {
  id: string;
  status: OrderStatus;
  client: OrderClientView;
  placedAt: string;
  totalAmount: string;
  lineCount: number;
}

export interface OrderPage {
  items: OrderSummaryView[];
  nextCursor: string | null;
}

/** Everything an OrderView needs, in one query. */
export const ORDER_VIEW_INCLUDE = {
  client: { select: { id: true, username: true, clinicName: true } },
  lines: {
    orderBy: { position: 'asc' },
    include: {
      item: {
        select: { id: true, nameAr: true, nameEn: true, unitLabelAr: true, imageUrl: true },
      },
      allocations: {
        orderBy: [{ batch: { expiryDate: 'asc' } }, { batch: { batchNumber: 'asc' } }],
        include: { batch: { select: { batchNumber: true, expiryDate: true } } },
      },
    },
  },
} satisfies Prisma.OrderInclude;

export type OrderWithRelations = Prisma.OrderGetPayload<{ include: typeof ORDER_VIEW_INCLUDE }>;

const iso = (d: Date | null): string | null => (d === null ? null : d.toISOString());

/** The one projection of an order. Every endpoint that returns an order uses it. */
export function toOrderView(row: OrderWithRelations): OrderView {
  return {
    id: row.id,
    status: row.status,
    client: { id: row.client.id, username: row.client.username, clinicName: row.client.clinicName },
    placedAt: row.placedAt.toISOString(),
    confirmedAt: iso(row.confirmedAt),
    dispatchedAt: iso(row.dispatchedAt),
    deliveredAt: iso(row.deliveredAt),
    cancelledAt: iso(row.cancelledAt),
    cancelReason: row.cancelReason,
    cancelDisposition: row.cancelDisposition,
    totalAmount: formatMoney(row.totalAmount),
    addressSnapshot: row.addressSnapshot,
    phoneSnapshot: row.phoneSnapshot,
    note: row.note,
    lines: row.lines.map((line) => {
      const approved = line.qtyUnitsApproved;
      return {
        id: line.id,
        itemId: line.itemId,
        position: line.position,
        item: {
          id: line.item.id,
          nameAr: line.item.nameAr,
          nameEn: line.item.nameEn,
          unitLabelAr: line.item.unitLabelAr,
          imageUrl: line.item.imageUrl,
        },
        unitsPerBoxSnapshot: line.unitsPerBoxSnapshot,
        pricePerBoxSnapshot: formatMoney(line.pricePerBoxSnapshot),
        lineTotal: formatMoney(line.lineTotal),
        qtyBoxesRequested: line.qtyBoxesRequested,
        qtyUnitsRequested: line.qtyUnitsRequested,
        qtyBoxesApproved: line.qtyBoxesApproved,
        qtyUnitsApproved: approved,
        qtyUnitsFulfilled: line.qtyUnitsFulfilled,
        // Two different reasons a line is short (D7), which the clinic must be
        // able to tell apart: the supplier cut it, or the warehouse ran out.
        adjustedBySupplier: approved !== null && approved < line.qtyUnitsRequested,
        shortByUnits: approved === null ? 0 : approved - line.qtyUnitsFulfilled,
        allocations: line.allocations.map((a) => ({
          batchId: a.batchId,
          batchNumber: a.batch.batchNumber,
          // @db.Date comes back as UTC midnight of that day, so this is the
          // calendar date exactly.
          expiryDate: a.batch.expiryDate.toISOString().slice(0, 10),
          qtyUnits: a.qtyUnits,
          released: a.releasedAt !== null,
        })),
      };
    }),
  };
}

/** Loads and projects one order, through `db` so it sees the caller's own uncommitted writes. */
export async function loadOrderView(db: Prisma.TransactionClient, orderId: string): Promise<OrderView> {
  const row = await db.order.findUnique({ where: { id: orderId }, include: ORDER_VIEW_INCLUDE });
  if (!row) {
    throw new AppException(HttpStatus.NOT_FOUND, 'ORDER_NOT_FOUND', ERROR_CODES.ORDER_NOT_FOUND);
  }
  return toOrderView(row);
}
