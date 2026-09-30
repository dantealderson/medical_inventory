import { Injectable, Logger } from '@nestjs/common';
import { type Notification, NotificationType, OrderStatus } from '@prisma/client';

import { ClientInventoryService } from '../client-inventory/client-inventory.service';
import { EstimationService } from '../estimation/estimation.service';
import { texts } from '../notifications/notification-texts';
import { NotificationsService } from '../notifications/notifications.service';
import { PrismaService } from '../prisma/prisma.service';
import { ORDER_TX_OPTIONS } from '../prisma/transaction';
import { lockOrder } from './order-lock';
import { assertTransition } from './order-state';
import { loadOrderView, type OrderView } from './order-views';

@Injectable()
export class OrderFulfilmentService {
  private readonly logger = new Logger(OrderFulfilmentService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly clientInventory: ClientInventoryService,
    private readonly estimation: EstimationService,
    private readonly notifications: NotificationsService,
  ) {}

  /**
   * CONFIRMED → OUT_FOR_DELIVERY. This writes no ledger row, because the
   * warehouse already let the goods go at CONFIRMED, and no audit entry,
   * because §7.9 does not list dispatch. `adminId` belongs to the transition
   * signature for Phase 5's order-status notification.
   */
  async dispatch(adminId: string, orderId: string): Promise<OrderView> {
    let created: Notification[] = [];
    const view = await this.prisma.$transaction(async (tx) => {
      // D1: a double-clicked dispatch queues here and gets a 409.
      const order = await lockOrder(tx, orderId);
      assertTransition(order.status, OrderStatus.OUT_FOR_DELIVERY);

      // dispatchedAt is load-bearing, not decoration. The disposition CHECK
      // reads it to know the goods left the building, and nothing else
      // permits a later WRITTEN_OFF.
      await tx.order.update({
        where: { id: orderId },
        data: { status: OrderStatus.OUT_FOR_DELIVERY, dispatchedAt: new Date() },
      });
      created = [
        await this.notifications.create(tx, {
          recipientUserId: order.clientId,
          type: NotificationType.ORDER_OUT_FOR_DELIVERY,
          ...texts.orderOutForDelivery(),
          payload: { orderId },
        }),
      ];
      return loadOrderView(tx, orderId);
    }, ORDER_TX_OPTIONS);
    await this.notifications.push(created);
    return view;
  }

  /** OUT_FOR_DELIVERY → DELIVERED: the clinic is credited with exactly what was allocated. */
  async deliver(adminId: string, orderId: string): Promise<OrderView> {
    let created: Notification[] = [];
    const delivered = await this.prisma.$transaction(async (tx) => {
      // D1: without this, a double-clicked deliver credits the clinic twice,
      // with its ledger and cache in agreement.
      const order = await lockOrder(tx, orderId);
      assertTransition(order.status, OrderStatus.DELIVERED);

      // Only live allocations count. Release runs only on cancel, which ends
      // the order, so an order that reached OUT_FOR_DELIVERY has none
      // released. The filter keeps delivery honest if that ever changes.
      const allocations = await tx.orderLineAllocation.findMany({
        where: { releasedAt: null, orderLine: { orderId } },
        select: { batchId: true, qtyUnits: true, orderLine: { select: { itemId: true } } },
        orderBy: [{ batchId: 'asc' }, { id: 'asc' }],
      });

      // Credit the batches FEFO chose, not a re-derivation. A Phase 5
      // "batch X expires on D" warning is only true if the holding names the
      // batch that physically arrived.
      await this.clientInventory.creditDelivery(tx, {
        clientId: order.clientId,
        orderId,
        actorUserId: adminId,
        portions: allocations.map((a) => ({
          itemId: a.orderLine.itemId,
          batchId: a.batchId,
          qtyUnits: a.qtyUnits,
        })),
      });

      // Deliberately no warehouse write here (D17).
      await tx.order.update({
        where: { id: orderId },
        data: { status: OrderStatus.DELIVERED, deliveredAt: new Date() },
      });
      created = [
        await this.notifications.create(tx, {
          recipientUserId: order.clientId,
          type: NotificationType.ORDER_DELIVERED,
          ...texts.orderDelivered(),
          payload: { orderId },
        }),
      ];
      return {
        view: await loadOrderView(tx, orderId),
        clientId: order.clientId,
        itemIds: [...new Set(allocations.map((a) => a.orderLine.itemId))],
      };
    }, ORDER_TX_OPTIONS);

    // After the commit: new purchases change a PURCHASE estimate. The delivery
    // already happened, so a failure here is logged, never reported as a
    // failed delivery; the nightly recompute catches up.
    try {
      await this.estimation.recomputeFor(delivered.clientId, delivered.itemIds);
    } catch (error) {
      this.logger.warn(`estimate recompute after delivering ${orderId} failed: ${String(error)}`);
    }
    await this.notifications.push(created);
    return delivered.view;
  }
}
