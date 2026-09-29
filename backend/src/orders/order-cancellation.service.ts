import { Injectable } from '@nestjs/common';
import { type CancelDisposition, OrderStatus } from '@prisma/client';

import { AllocationService } from '../allocation/allocation.service';
import { AuditService } from '../audit/audit.service';
import { PrismaService } from '../prisma/prisma.service';
import { ORDER_TX_OPTIONS } from '../prisma/transaction';
import type { AdminCancelOrderDto, ClientCancelOrderDto } from './dto/cancel-order.dto';
import { lockOrder } from './order-lock';
import { resolveCancellation, type CancelActor } from './order-state';
import { loadOrderView, type OrderView } from './order-views';

interface CancelCommand {
  actor: CancelActor;
  actorUserId: string;
  orderId: string;
  /** Set only for a client. It scopes the lock to that client's own orders (D10). */
  clientId?: string;
  requested?: CancelDisposition;
  reason?: string;
}

@Injectable()
export class OrderCancellationService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly allocation: AllocationService,
    private readonly audit: AuditService,
  ) {}

  cancelByClient(clientId: string, orderId: string, dto: ClientCancelOrderDto): Promise<OrderView> {
    return this.cancel({
      actor: 'CLIENT',
      actorUserId: clientId,
      orderId,
      clientId,
      reason: dto.reason,
    });
  }

  cancelByAdmin(adminId: string, orderId: string, dto: AdminCancelOrderDto): Promise<OrderView> {
    return this.cancel({
      actor: 'ADMIN',
      actorUserId: adminId,
      orderId,
      requested: dto.disposition,
      reason: dto.reason,
    });
  }

  private cancel(cmd: CancelCommand): Promise<OrderView> {
    return this.prisma.$transaction(async (tx) => {
      // D1: the order row first. The status the matrix reads is the one this
      // lock returns, so a double-clicked cancel, or a cancel racing a
      // confirm, sees the winner's committed status and gets a 409.
      // With a clientId the lock finds only that clinic's orders, so another
      // clinic's order id is a 404, indistinguishable from none (D10).
      const order = await lockOrder(tx, cmd.orderId, cmd.clientId);

      // The whole §7.4 matrix lives in resolveCancellation, as data. There is
      // no status if-chain here, because a second copy of the rules is how
      // the two copies drift apart.
      const outcome = resolveCancellation(order.status, cmd.actor, cmd.requested);

      // Release only when the goods are, or came back, in the warehouse.
      // WRITTEN_OFF releases nothing and writes nothing: the units already
      // left the ledger at CONFIRMED, and a movement now would subtract them
      // a second time.
      const released = outcome.releasesStock
        ? await this.allocation.release(tx, cmd.orderId, cmd.actorUserId)
        : [];
      const releasedUnits = released.reduce((sum, p) => sum + p.qtyUnits, 0);

      // The disposition always comes from the matrix, never straight from the
      // request. The orders_cancel_disposition_consistent CHECK is the second
      // line of defence.
      await tx.order.update({
        where: { id: cmd.orderId },
        data: {
          status: OrderStatus.CANCELLED,
          cancelledAt: new Date(),
          cancelDisposition: outcome.disposition,
          cancelReason: cmd.reason ?? null,
        },
      });

      // D9: recorded with tx, so the log can never claim a cancel that
      // rolled back.
      await this.audit.record(
        {
          actorUserId: cmd.actorUserId,
          action: 'ORDER_CANCELLED',
          entityType: 'order',
          entityId: cmd.orderId,
          after: {
            from: order.status,
            disposition: outcome.disposition,
            releasedUnits,
            reason: cmd.reason ?? null,
          },
        },
        tx,
      );

      return loadOrderView(tx, cmd.orderId);
    }, ORDER_TX_OPTIONS);
  }
}
