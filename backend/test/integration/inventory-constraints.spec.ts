import { Test } from '@nestjs/testing';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { AppConfigModule } from '../../src/config/config.module';
import { PrismaService } from '../../src/prisma/prisma.service';
import { createCatalogItem, createClient } from '../helpers/fixtures';
import { resetDb } from '../helpers/reset-db';

/**
 * Phase 4's CHECK constraints. As in Phase 3, every violation is asserted by
 * constraint name, and each group has a positive control, so a test cannot
 * stay green by failing for some other reason once the constraint is gone.
 */
describe('Phase 4 CHECK constraints (integration)', () => {
  let prisma: PrismaService;
  let clientId: string;
  let itemId: string;

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
    clientId = await createClient(prisma, 'constraint_probe');
    ({ itemId } = await createCatalogItem(prisma));
  });

  afterAll(async () => {
    await resetDb(prisma);
    await prisma.$disconnect();
  });

  // ── stock_count_lines_sane ─────────────────────────────────────────────────

  describe('stock_count_lines_sane', () => {
    async function insertLine(counted: number, previous: number, delta: number): Promise<number> {
      const [count] = await prisma.$queryRaw<Array<{ id: string }>>`
        INSERT INTO "stock_counts" (id, "clientId", "countedAt", "createdByUserId", "createdAt")
        VALUES (gen_random_uuid(), ${clientId}, now(), ${clientId}, now())
        RETURNING id`;
      return prisma.$executeRaw`
        INSERT INTO "stock_count_lines"
          (id, "stockCountId", "itemId", "countedQtyUnits", "previousQtyUnits", "deltaUnits")
        VALUES (gen_random_uuid(), ${count.id}, ${itemId}, ${counted}, ${previous}, ${delta})`;
    }

    it('accepts a line whose delta is counted minus previous', async () => {
      await expect(insertLine(240, 300, -60)).resolves.toBe(1);
      await expect(insertLine(0, 0, 0)).resolves.toBe(1);
    });

    it('rejects a delta that is not counted minus previous', async () => {
      await expect(insertLine(240, 300, 60)).rejects.toThrow(/stock_count_lines_sane/);
    });

    it('rejects a negative count', async () => {
      await expect(insertLine(-1, 0, -1)).rejects.toThrow(/stock_count_lines_sane/);
    });
  });

  // ── usage_estimates_rate_matches_source ────────────────────────────────────

  describe('usage_estimates_rate_matches_source', () => {
    function insertEstimate(
      source: string,
      rate: string | null,
      confidence: string | null,
      sampleDays: number | null = null,
    ): Promise<number> {
      return prisma.$executeRaw`
        INSERT INTO "usage_estimates"
          ("clientId", "itemId", "ratePerDay", "source", "confidence", "sampleDays", "computedAt")
        VALUES (${clientId}, ${itemId}, ${rate}::numeric, ${source}::"EstimateSource",
                ${confidence}::"EstimateConfidence", ${sampleDays}, now())`;
    }

    it('accepts a measured rate with a confidence, and a NONE with neither', async () => {
      await expect(insertEstimate('MEASURED', '2.0000', 'HIGH', 10)).resolves.toBe(1);
      await prisma.usageEstimate.deleteMany();
      await expect(insertEstimate('NONE', null, null)).resolves.toBe(1);
      await prisma.usageEstimate.deleteMany();
      await expect(insertEstimate('MANUAL', '0', null)).resolves.toBe(1);
    });

    it('rejects a NONE estimate that carries a rate', async () => {
      // Stored as 0, "no data" would read as "uses nothing": a false green.
      await expect(insertEstimate('NONE', '0', null)).rejects.toThrow(
        /usage_estimates_rate_matches_source/,
      );
    });

    it('rejects a computed estimate without a rate', async () => {
      await expect(insertEstimate('PURCHASE', null, 'LOW')).rejects.toThrow(
        /usage_estimates_rate_matches_source/,
      );
    });

    it('rejects a MANUAL rate that claims a confidence', async () => {
      await expect(insertEstimate('MANUAL', '2.5', 'HIGH')).rejects.toThrow(
        /usage_estimates_rate_matches_source/,
      );
    });

    it('rejects a computed estimate without a confidence', async () => {
      await expect(insertEstimate('PURCHASE', '10', null)).rejects.toThrow(
        /usage_estimates_rate_matches_source/,
      );
    });

    it('rejects a negative rate and negative sample days', async () => {
      await expect(insertEstimate('MEASURED', '-1', 'HIGH')).rejects.toThrow(
        /usage_estimates_rate_matches_source/,
      );
      await expect(insertEstimate('MEASURED', '1', 'HIGH', -1)).rejects.toThrow(
        /usage_estimates_rate_matches_source/,
      );
    });
  });
});
