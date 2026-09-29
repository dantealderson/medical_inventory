import { Test } from '@nestjs/testing';
import { MovementReason, OwnerType } from '@prisma/client';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { AppConfigModule } from '../../src/config/config.module';
import { PrismaService } from '../../src/prisma/prisma.service';
import { createCatalogItem, createClient, receiveBatch } from '../helpers/fixtures';
import {
  expectClientLedgerMatchesCache,
  expectWarehouseLedgerMatchesCache,
} from '../helpers/ledger';
import { resetDb } from '../helpers/reset-db';

describe('ledger assertions (integration)', () => {
  let prisma: PrismaService;
  let clientId: string;
  let itemId: string;
  let batchId: string;

  beforeAll(async () => {
    const ref = await Test.createTestingModule({
      imports: [AppConfigModule],
      providers: [PrismaService],
    }).compile();
    prisma = ref.get(PrismaService);
    await prisma.$connect();
  });

  beforeEach(async () => {
    await resetDb(prisma);
    clientId = await createClient(prisma, 'ledger_probe');
    ({ itemId } = await createCatalogItem(prisma, { unitsPerBox: 10 }));
    batchId = await receiveBatch(prisma, {
      itemId,
      batchNumber: 'B1',
      expiryDate: '2030-01-01',
      boxes: 3,
      unitsPerBox: 10,
    });
  });

  afterAll(async () => {
    await resetDb(prisma);
    await prisma.$disconnect();
  });

  describe('expectWarehouseLedgerMatchesCache', () => {
    it('passes for a batch received with its movement', async () => {
      await expect(expectWarehouseLedgerMatchesCache(prisma)).resolves.toBeUndefined();
    });

    it('fails when the cache moved without a movement', async () => {
      await prisma.warehouseBatch.update({
        where: { id: batchId },
        data: { qtyUnitsRemaining: { decrement: 1 } },
      });
      await expect(expectWarehouseLedgerMatchesCache(prisma)).rejects.toThrow(/cache disagrees/);
    });

    it('fails when a movement was written without moving the cache', async () => {
      await prisma.stockMovement.create({
        data: {
          ownerType: OwnerType.ADMIN,
          itemId,
          batchId,
          qtyUnitsDelta: -5,
          reason: MovementReason.ORDER_OUT,
        },
      });
      await expect(expectWarehouseLedgerMatchesCache(prisma)).rejects.toThrow(/cache disagrees/);
    });

    it('fails on a warehouse movement that names no batch', async () => {
      await prisma.stockMovement.create({
        data: {
          ownerType: OwnerType.ADMIN,
          itemId,
          batchId: null,
          qtyUnitsDelta: -5,
          reason: MovementReason.ORDER_OUT,
        },
      });
      await expect(expectWarehouseLedgerMatchesCache(prisma)).rejects.toThrow(/no batch/);
    });

    it('does not count client movements against a batch', async () => {
      await prisma.stockMovement.create({
        data: {
          ownerType: OwnerType.CLIENT,
          clientId,
          itemId,
          batchId,
          qtyUnitsDelta: 10,
          reason: MovementReason.DELIVERY_IN,
        },
      });
      await expect(expectWarehouseLedgerMatchesCache(prisma)).resolves.toBeUndefined();
    });
  });

  describe('expectClientLedgerMatchesCache', () => {
    /** A consistent credit: movement, cache and holding all +units. */
    async function credit(forClient: string, units: number): Promise<void> {
      await prisma.stockMovement.create({
        data: {
          ownerType: OwnerType.CLIENT,
          clientId: forClient,
          itemId,
          batchId,
          qtyUnitsDelta: units,
          reason: MovementReason.DELIVERY_IN,
        },
      });
      await prisma.clientInventoryItem.create({
        data: { clientId: forClient, itemId, qtyUnits: units },
      });
      await prisma.clientBatchHolding.create({
        data: { clientId: forClient, batchId, qtyUnits: units },
      });
    }

    it('passes when movements, cache and holdings agree', async () => {
      await credit(clientId, 20);
      await expect(expectClientLedgerMatchesCache(prisma, clientId)).resolves.toBeUndefined();
    });

    it('fails when the cache disagrees', async () => {
      await credit(clientId, 20);
      await prisma.clientInventoryItem.update({
        where: { clientId_itemId: { clientId, itemId } },
        data: { qtyUnits: 21 },
      });
      await expect(expectClientLedgerMatchesCache(prisma, clientId)).rejects.toThrow(/disagree/);
    });

    it('fails when the holdings disagree', async () => {
      await credit(clientId, 20);
      await prisma.clientBatchHolding.updateMany({ where: { clientId }, data: { qtyUnits: 19 } });
      await expect(expectClientLedgerMatchesCache(prisma, clientId)).rejects.toThrow(/disagree/);
    });

    it('fails when movements exist but no cache row does', async () => {
      await prisma.stockMovement.create({
        data: {
          ownerType: OwnerType.CLIENT,
          clientId,
          itemId,
          batchId,
          qtyUnitsDelta: 10,
          reason: MovementReason.DELIVERY_IN,
        },
      });
      await expect(expectClientLedgerMatchesCache(prisma, clientId)).rejects.toThrow(/disagree/);
    });

    it("looks only at the given client", async () => {
      const other = await createClient(prisma, 'other_clinic');
      await credit(clientId, 20);
      await credit(other, 5);
      await prisma.clientInventoryItem.update({
        where: { clientId_itemId: { clientId: other, itemId } },
        data: { qtyUnits: 999 },
      });
      await expect(expectClientLedgerMatchesCache(prisma, clientId)).resolves.toBeUndefined();
      await expect(expectClientLedgerMatchesCache(prisma, other)).rejects.toThrow(/disagree/);
    });
  });
});
