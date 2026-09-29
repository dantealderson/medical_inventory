import { Injectable } from '@nestjs/common';
import { MovementReason, OwnerType, type Prisma } from '@prisma/client';

export interface DeliveryPortion {
  itemId: string;
  batchId: string;
  qtyUnits: number;
}

/**
 * Stock on the clinic's own shelf. Phase 3 only credits it, on DELIVERED;
 * Phase 4 adds counts, the estimator and auto-decrement on the same rows.
 */
@Injectable()
export class ClientInventoryService {
  /**
   * Credits a delivery inside the caller's transaction.
   * - Per batch: a ClientBatchHolding and a DELIVERY_IN movement.
   * - Per item: the ClientInventoryItem cache.
   * It touches no warehouse row. Those units left the warehouse ledger at
   * CONFIRMED, and subtracting them again would double-count.
   */
  async creditDelivery(
    tx: Prisma.TransactionClient,
    input: { clientId: string; orderId: string; actorUserId: string; portions: DeliveryPortion[] },
  ): Promise<void> {
    // Sorted, so two deliveries to one clinic upsert the rows they share in
    // the same order and cannot deadlock each other.
    const portions = [...input.portions].sort((a, b) => compare(a.batchId, b.batchId));

    for (const p of portions) {
      // A raw upsert, not prisma.upsert. ON CONFLICT is one atomic statement,
      // whereas a read-then-write upsert can race a concurrent delivery into a
      // P2002. `id` (@default(uuid())) and `updatedAt` (@updatedAt) are filled
      // in by Prisma's client, not by the database, so raw SQL must supply them.
      await tx.$executeRaw`
        INSERT INTO "client_batch_holdings" ("id", "clientId", "batchId", "qtyUnits", "createdAt", "updatedAt")
        VALUES (gen_random_uuid(), ${input.clientId}, ${p.batchId}, ${p.qtyUnits}::int, now(), now())
        ON CONFLICT ("clientId", "batchId") DO UPDATE
          SET "qtyUnits" = "client_batch_holdings"."qtyUnits" + EXCLUDED."qtyUnits",
              "updatedAt" = now()`;

      // §5: the ledger row for the same change, in the same transaction. The
      // batchId is what later lets Phase 5 warn this clinic that batch X
      // expires on date D.
      await tx.stockMovement.create({
        data: {
          ownerType: OwnerType.CLIENT,
          clientId: input.clientId,
          itemId: p.itemId,
          batchId: p.batchId,
          qtyUnitsDelta: p.qtyUnits,
          reason: MovementReason.DELIVERY_IN,
          refType: 'order',
          refId: input.orderId,
          actorUserId: input.actorUserId,
        },
      });
    }

    const perItem = new Map<string, number>();
    for (const p of portions) {
      perItem.set(p.itemId, (perItem.get(p.itemId) ?? 0) + p.qtyUnits);
    }

    for (const [itemId, qtyUnits] of [...perItem].sort(([a], [b]) => compare(a, b))) {
      // Phase 4's estimator and status badges read this cache. Phase 3
      // invariant, asserted by expectClientLedgerMatchesCache, per item:
      // Σ holdings == qtyUnits == Σ CLIENT movements.
      await tx.$executeRaw`
        INSERT INTO "client_inventory_items" ("clientId", "itemId", "qtyUnits", "createdAt", "updatedAt")
        VALUES (${input.clientId}, ${itemId}, ${qtyUnits}::int, now(), now())
        ON CONFLICT ("clientId", "itemId") DO UPDATE
          SET "qtyUnits" = "client_inventory_items"."qtyUnits" + EXCLUDED."qtyUnits",
              "updatedAt" = now()`;
    }
  }
}

/** Plain code-unit order: locale-free, and the same on every call. */
function compare(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}
