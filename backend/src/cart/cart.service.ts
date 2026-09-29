import { HttpStatus, Injectable } from '@nestjs/common';
import type { Item, Prisma } from '@prisma/client';

import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import { billedAmount, formatMoney, sumMoney } from '../common/money';
import { boxesToUnits } from '../common/units';
import { itemToView, type ItemView } from '../items/items.service';
import { PrismaService } from '../prisma/prisma.service';
import type { AddCartLineDto } from './dto/add-cart-line.dto';
import type { SetCartLineDto } from './dto/set-cart-line.dto';

export interface CartLineView {
  itemId: string;
  item: ItemView;
  qtyBoxes: number;
  qtyUnits: number;
  /** At the LIVE price. Prices are snapshotted at placement, not here. */
  lineTotal: string;
  /** False once the item is deactivated. Placement refuses the cart until the line is removed. */
  isAvailable: boolean;
}

export interface CartView {
  lines: CartLineView[];
  /** Every line, available or not: the badge must show there is something to deal with. */
  lineCount: number;
  /** Available lines only: what an order placed now would cost. */
  totalAmount: string;
}

/** The cart_lines_qty_range CHECK (D15). */
const MAX_LINE_BOXES = 999;

/**
 * The most base units one line may stand for. Placement stores
 * qtyBoxes × unitsPerBox in an int4 column (max 2 147 483 647). Without this
 * limit, a big enough box size would overflow it and fail the order with a
 * 500. A billion is far beyond any real order and well inside int4.
 */
const MAX_LINE_UNITS = 1_000_000_000;

/** The most boxes of this item one line may hold. */
function maxBoxesFor(unitsPerBox: number): number {
  return Math.min(MAX_LINE_BOXES, Math.floor(MAX_LINE_UNITS / unitsPerBox));
}

const lineLimit = () =>
  new AppException(HttpStatus.BAD_REQUEST, 'CART_LINE_LIMIT', ERROR_CODES.CART_LINE_LIMIT);

const lineNotFound = () =>
  new AppException(HttpStatus.NOT_FOUND, 'CART_LINE_NOT_FOUND', ERROR_CODES.CART_LINE_NOT_FOUND);

@Injectable()
export class CartService {
  constructor(private readonly prisma: PrismaService) {}

  async get(clientId: string): Promise<CartView> {
    const rows = await this.prisma.cartLine.findMany({
      where: { cart: { clientId } },
      orderBy: [{ addedAt: 'asc' }, { id: 'asc' }],
      include: { item: true },
    });
    const lines = rows.map((row) => priced(row.itemId, row.qtyBoxes, row.item));
    return {
      lines: lines.map((l) => l.view),
      lineCount: lines.length,
      totalAmount: formatMoney(sumMoney(lines.filter((l) => l.view.isAvailable).map((l) => l.total))),
    };
  }

  async addLine(clientId: string, dto: AddCartLineDto): Promise<CartView> {
    const item = await this.orderableItem(dto.itemId);
    const maxBoxes = maxBoxesFor(item.unitsPerBox);
    if (dto.qtyBoxes > maxBoxes) throw lineLimit();

    // D15: race-free by construction. Five rapid taps are five concurrent
    // requests. A read followed by a write (Prisma's upsert included) lets two
    // of them both see "nothing yet", and the second insert fails with P2002,
    // a 500. INSERT … ON CONFLICT decides "insert or update" inside Postgres,
    // on the unique index, in one statement.
    const now = new Date();
    const [cart] = await this.prisma.$queryRaw<Array<{ id: string }>>`
      INSERT INTO "carts" (id, "clientId", "createdAt", "updatedAt")
      VALUES (gen_random_uuid(), ${clientId}, ${now}, ${now})
      ON CONFLICT ("clientId") DO UPDATE SET "updatedAt" = EXCLUDED."updatedAt"
      RETURNING id`;

    // The WHERE makes the limit check and the addition one atomic step, so two
    // concurrent adds cannot both pass it. When it is false, nothing is
    // written and the statement reports 0 rows.
    const affected = await this.prisma.$executeRaw`
      INSERT INTO "cart_lines" (id, "cartId", "itemId", "qtyBoxes", "addedAt")
      VALUES (gen_random_uuid(), ${cart.id}, ${item.id}, ${dto.qtyBoxes}, ${now})
      ON CONFLICT ("cartId", "itemId") DO UPDATE
        SET "qtyBoxes" = "cart_lines"."qtyBoxes" + EXCLUDED."qtyBoxes"
        WHERE "cart_lines"."qtyBoxes" + EXCLUDED."qtyBoxes" <= ${maxBoxes}`;
    if (affected === 0) throw lineLimit();

    return this.get(clientId);
  }

  /** Sets the quantity absolutely. 0 removes the line. */
  async setLine(clientId: string, itemId: string, dto: SetCartLineDto): Promise<CartView> {
    if (dto.qtyBoxes === 0) {
      const { count } = await this.prisma.cartLine.deleteMany({
        where: { itemId, cart: { clientId } },
      });
      if (count === 0) throw lineNotFound();
      return this.get(clientId);
    }

    const line = await this.prisma.cartLine.findFirst({
      where: { itemId, cart: { clientId } },
      include: { item: { select: { unitsPerBox: true } } },
    });
    if (!line) throw lineNotFound();
    if (dto.qtyBoxes > maxBoxesFor(line.item.unitsPerBox)) throw lineLimit();

    const { count } = await this.prisma.cartLine.updateMany({
      where: { id: line.id },
      data: { qtyBoxes: dto.qtyBoxes },
    });
    // The line was removed between the read and the write, for example by
    // the same clinic on another device.
    if (count === 0) throw lineNotFound();
    return this.get(clientId);
  }

  /** Idempotent: removing a line that is not there is not an error. */
  async removeLine(clientId: string, itemId: string): Promise<void> {
    await this.prisma.cartLine.deleteMany({ where: { itemId, cart: { clientId } } });
  }

  async clear(clientId: string): Promise<void> {
    await this.prisma.cartLine.deleteMany({ where: { cart: { clientId } } });
  }

  private async orderableItem(itemId: string): Promise<Item> {
    const item = await this.prisma.item.findUnique({ where: { id: itemId } });
    if (!item) {
      throw new AppException(HttpStatus.NOT_FOUND, 'ITEM_NOT_FOUND', ERROR_CODES.ITEM_NOT_FOUND);
    }
    // Checked here, explicitly: GET /items/:id returns deactivated items
    // (admins need them), so reaching an item's page proves nothing.
    if (!item.isActive) {
      throw new AppException(HttpStatus.CONFLICT, 'ITEM_UNAVAILABLE', ERROR_CODES.ITEM_UNAVAILABLE);
    }
    return item;
  }
}

/** One line at the live price, plus its total as a Decimal for summing. */
function priced(
  itemId: string,
  qtyBoxes: number,
  item: Item,
): { view: CartLineView; total: Prisma.Decimal } {
  const qtyUnits = boxesToUnits(qtyBoxes, item.unitsPerBox);
  const total = billedAmount(item.pricePerBox, qtyUnits, item.unitsPerBox);
  return {
    view: {
      itemId,
      item: itemToView(item),
      qtyBoxes,
      qtyUnits,
      lineTotal: formatMoney(total),
      isAvailable: item.isActive,
    },
    total,
  };
}
