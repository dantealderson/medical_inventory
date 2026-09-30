import { HttpStatus, Injectable } from '@nestjs/common';
import { type Notification, NotificationType, OrderStatus, UserStatus, type Prisma } from '@prisma/client';

import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import { billedAmount, formatMoney, sumMoney } from '../common/money';
import { boxesToUnits } from '../common/units';
import { texts } from '../notifications/notification-texts';
import { NotificationsService } from '../notifications/notifications.service';
import { PrismaService } from '../prisma/prisma.service';
import { ORDER_TX_OPTIONS } from '../prisma/transaction';
import type { AdminListOrdersDto, ListOrdersDto } from './dto/list-orders.dto';
import type { PlaceOrderDto } from './dto/place-order.dto';
import {
  ORDER_VIEW_INCLUDE,
  loadOrderView,
  toOrderView,
  type OrderPage,
  type OrderView,
} from './order-views';

/** Statuses the admin works through in arrival order: the oldest waiting order first. */
const WORK_QUEUE = new Set<OrderStatus>([
  OrderStatus.PLACED,
  OrderStatus.CONFIRMED,
  OrderStatus.OUT_FOR_DELIVERY,
]);

const DEFAULT_PAGE_SIZE = 20;

const orderNotFound = () =>
  new AppException(HttpStatus.NOT_FOUND, 'ORDER_NOT_FOUND', ERROR_CODES.ORDER_NOT_FOUND);

@Injectable()
export class OrdersService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly notifications: NotificationsService,
  ) {}

  /**
   * Cart → PLACED (§7.4). Snapshots everything a later change could rewrite,
   * and moves no stock (D17).
   */
  async place(clientId: string, dto: PlaceOrderDto): Promise<OrderView> {
    let created: Notification[] = [];
    const view = await this.prisma.$transaction(async (tx) => {
      // D16: lock the cart row first. A double-tapped "place order" is two
      // concurrent requests, and without the lock both read the same lines
      // and create two orders. The second request waits here, then reads the
      // lines the first one deleted, and gets CART_EMPTY.
      const carts = await tx.$queryRaw<Array<{ id: string }>>`
        SELECT id FROM "carts" WHERE "clientId" = ${clientId} FOR UPDATE`;

      // D16: re-read the account inside the transaction. The access token
      // outlives a suspension by up to 15 minutes, and the JWT guard does not
      // look at the database.
      const client = await tx.user.findUniqueOrThrow({
        where: { id: clientId },
        select: { status: true, address: true, phone: true, clinicName: true, username: true },
      });
      if (client.status !== UserStatus.ACTIVE) {
        throw new AppException(
          HttpStatus.FORBIDDEN,
          'ACCOUNT_SUSPENDED',
          ERROR_CODES.ACCOUNT_SUSPENDED,
        );
      }

      const cartLines =
        carts.length === 0
          ? []
          : await tx.cartLine.findMany({
              where: { cartId: carts[0].id },
              orderBy: [{ addedAt: 'asc' }, { id: 'asc' }],
              include: { item: true },
            });
      if (cartLines.length === 0) {
        throw new AppException(HttpStatus.CONFLICT, 'CART_EMPTY', ERROR_CODES.CART_EMPTY);
      }

      // Refuse the whole cart rather than silently dropping lines. The clinic
      // must see which items went away. Nothing is written, so the cart is
      // left exactly as it was.
      const unavailable = cartLines.filter((l) => !l.item.isActive).map((l) => l.itemId);
      if (unavailable.length > 0) {
        throw new AppException(
          HttpStatus.CONFLICT,
          'CART_HAS_UNAVAILABLE_ITEMS',
          ERROR_CODES.CART_HAS_UNAVAILABLE_ITEMS,
          { itemIds: unavailable },
        );
      }

      // Snapshots: an item repriced or re-boxed next month must not rewrite
      // this order. lineTotal = price × boxes (D8), and the total is always
      // the sum of the lines, never computed on its own.
      const lines = cartLines.map((line, position) => {
        const qtyUnitsRequested = boxesToUnits(line.qtyBoxes, line.item.unitsPerBox);
        return {
          itemId: line.itemId,
          position,
          qtyBoxesRequested: line.qtyBoxes,
          qtyUnitsRequested,
          unitsPerBoxSnapshot: line.item.unitsPerBox,
          pricePerBoxSnapshot: line.item.pricePerBox,
          lineTotal: billedAmount(line.item.pricePerBox, qtyUnitsRequested, line.item.unitsPerBox),
        };
      });

      const order = await tx.order.create({
        data: {
          clientId,
          totalAmount: sumMoney(lines.map((l) => l.lineTotal)),
          addressSnapshot: client.address,
          phoneSnapshot: client.phone,
          note: dto.note ?? null,
          lines: { create: lines },
        },
        select: { id: true },
      });
      await tx.cartLine.deleteMany({ where: { cartId: carts[0].id } });

      created = await this.notifications.createForAdmins(tx, {
        type: NotificationType.ORDER_PLACED,
        ...texts.orderPlaced(client.clinicName ?? client.username),
        payload: { orderId: order.id },
      });
      return loadOrderView(tx, order.id);
    }, ORDER_TX_OPTIONS);
    await this.notifications.push(created);
    return view;
  }

  /** The clinic's own orders, newest first. */
  listForClient(clientId: string, query: ListOrdersDto): Promise<OrderPage> {
    return this.page({ clientId }, 'desc', query);
  }

  /**
   * Every clinic's orders. Filtered to a status the admin works through
   * (PLACED, CONFIRMED, OUT_FOR_DELIVERY), the list is a queue: oldest
   * first. Otherwise it is history: newest first.
   */
  listForAdmin(query: AdminListOrdersDto): Promise<OrderPage> {
    const direction = query.status && WORK_QUEUE.has(query.status) ? 'asc' : 'desc';
    return this.page(
      {
        ...(query.status ? { status: query.status } : {}),
        ...(query.clientId ? { clientId: query.clientId } : {}),
      },
      direction,
      query,
    );
  }

  /** 404 for another clinic's order (D10): a 403 would confirm that the id exists. */
  async getForClient(clientId: string, orderId: string): Promise<OrderView> {
    const row = await this.prisma.order.findFirst({
      where: { id: orderId, clientId },
      include: ORDER_VIEW_INCLUDE,
    });
    if (!row) throw orderNotFound();
    return toOrderView(row);
  }

  getForAdmin(orderId: string): Promise<OrderView> {
    return loadOrderView(this.prisma, orderId);
  }

  private async page(
    where: Prisma.OrderWhereInput,
    direction: Prisma.SortOrder,
    query: ListOrdersDto,
  ): Promise<OrderPage> {
    const limit = query.limit ?? DEFAULT_PAGE_SIZE;
    const rows = await this.prisma.order.findMany({
      where,
      // placedAt alone is not a total order. Two orders in the same
      // millisecond would make a page boundary skip or repeat one of them.
      orderBy: [{ placedAt: direction }, { id: direction }],
      take: limit + 1,
      ...(query.cursor ? { cursor: { id: query.cursor }, skip: 1 } : {}),
      include: {
        client: { select: { id: true, username: true, clinicName: true } },
        _count: { select: { lines: true } },
      },
    });
    const hasMore = rows.length > limit;
    const page = hasMore ? rows.slice(0, limit) : rows;
    return {
      items: page.map((row) => ({
        id: row.id,
        status: row.status,
        client: row.client,
        placedAt: row.placedAt.toISOString(),
        totalAmount: formatMoney(row.totalAmount),
        lineCount: row._count.lines,
      })),
      nextCursor: hasMore ? page[page.length - 1].id : null,
    };
  }
}
