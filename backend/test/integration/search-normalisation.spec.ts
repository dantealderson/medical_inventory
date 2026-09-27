import { Test } from '@nestjs/testing';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { AppConfigModule } from '../../src/config/config.module';
import { PrismaService } from '../../src/prisma/prisma.service';

describe('search_normalize_v1 (integration)', () => {
  let prisma: PrismaService;

  async function normalise(input: string): Promise<string> {
    const rows = await prisma.$queryRawUnsafe<{ out: string }[]>(
      'SELECT search_normalize_v1($1) AS out',
      input,
    );
    return rows[0].out;
  }

  beforeAll(async () => {
    const ref = await Test.createTestingModule({
      imports: [AppConfigModule],
      providers: [PrismaService],
    }).compile();
    prisma = ref.get(PrismaService);
    await prisma.$connect();
  });

  afterAll(async () => {
    await prisma.$disconnect();
  });

  it('lowercases Latin text', async () => {
    await expect(normalise('SYRINGE')).resolves.toBe('syringe');
  });

  it('strips harakat', async () => {
    expect(await normalise('سِرِنْجَة')).toBe(await normalise('سرنجة'));
  });

  it('strips tatweel', async () => {
    expect(await normalise('سرنـــجة')).toBe(await normalise('سرنجة'));
  });

  it('folds every alef variant to ا', async () => {
    for (const variant of ['أحمد', 'إحمد', 'آحمد', 'ٱحمد']) {
      await expect(normalise(variant)).resolves.toBe('احمد');
    }
  });

  it('folds ة to ه — clinics type both interchangeably', async () => {
    expect(await normalise('سرنجة')).toBe(await normalise('سرنجه'));
  });

  it('folds ى to ي', async () => {
    expect(await normalise('مستشفى')).toBe(await normalise('مستشفي'));
  });

  it('folds ؤ to و and ئ to ي', async () => {
    expect(await normalise('مسؤول')).toBe(await normalise('مسوول'));
    expect(await normalise('سائل')).toBe(await normalise('سايل'));
  });

  it('folds Arabic-Indic digits to Latin', async () => {
    // The app renders Arabic-Indic numerals, but sizes and batch numbers get
    // typed either way — "سرنجة ٥ مل" and "سرنجة 5 مل" must match.
    await expect(normalise('٥ مل')).resolves.toBe('5 مل');
    await expect(normalise('٠١٢٣٤٥٦٧٨٩')).resolves.toBe('0123456789');
  });

  it('collapses whitespace and trims', async () => {
    await expect(normalise('  قفازات   طبية  ')).resolves.toBe('قفازات طبيه');
  });

  it('is null-safe via STRICT', async () => {
    const rows = await prisma.$queryRawUnsafe<{ out: string | null }[]>(
      'SELECT search_normalize_v1(NULL) AS out',
    );
    expect(rows[0].out).toBeNull();
  });

  it('is IMMUTABLE, which indexing depends on', async () => {
    // provolatile is PostgreSQL's internal "char" type, which Prisma's raw
    // mapper cannot represent — cast it to text.
    const rows = await prisma.$queryRawUnsafe<{ volatility: string }[]>(
      `SELECT provolatile::text AS volatility FROM pg_proc WHERE proname = 'search_normalize_v1'`,
    );
    expect(rows[0].volatility).toBe('i');
  });
});

describe('items.searchText trigger (integration)', () => {
  let prisma: PrismaService;
  let categoryId: string;

  beforeAll(async () => {
    const ref = await Test.createTestingModule({
      imports: [AppConfigModule],
      providers: [PrismaService],
    }).compile();
    prisma = ref.get(PrismaService);
    await prisma.$connect();
  });

  beforeEach(async () => {
    await prisma.stockMovement.deleteMany();
    await prisma.warehouseBatch.deleteMany();
    await prisma.item.deleteMany();
    await prisma.category.deleteMany();
    const c = await prisma.category.create({ data: { nameAr: 'مستهلكات', level: 1 } });
    categoryId = c.id;
  });

  afterAll(async () => {
    await prisma.stockMovement.deleteMany();
    await prisma.warehouseBatch.deleteMany();
    await prisma.item.deleteMany();
    await prisma.category.deleteMany();
    await prisma.$disconnect();
  });

  async function searchTextOf(id: string): Promise<string | null> {
    const rows = await prisma.$queryRawUnsafe<{ searchText: string | null }[]>(
      'SELECT "searchText" FROM items WHERE id = $1',
      id,
    );
    return rows[0].searchText;
  }

  const base = {
    categoryId: '',
    unitsPerBox: 100,
    unitLabelAr: 'سرنجة',
    pricePerBox: '12.50',
  };

  it('populates searchText on insert, normalised', async () => {
    const item = await prisma.item.create({
      data: { ...base, categoryId, nameAr: 'سِرِنْجَة ٥ مل', nameEn: 'Syringe 5ml' },
    });
    expect(await searchTextOf(item.id)).toBe('سرنجه 5 مل syringe 5ml');
  });

  it('refreshes searchText when a name changes', async () => {
    const item = await prisma.item.create({
      data: { ...base, categoryId, nameAr: 'سرنجة' },
    });
    await prisma.item.update({ where: { id: item.id }, data: { nameAr: 'قفازات' } });
    expect(await searchTextOf(item.id)).toContain('قفازات');
  });

  it('never leaves searchText NULL for an English-only item', async () => {
    // Without coalesce, NULL || ' ' || 'Gloves' is NULL — and the item would
    // render fine in browse while being permanently invisible to search.
    const item = await prisma.item.create({
      data: { ...base, categoryId, nameAr: null, nameEn: 'Gloves' },
    });
    expect(await searchTextOf(item.id)).toBe('gloves');
  });

  it('never leaves searchText NULL for an Arabic-only item', async () => {
    const item = await prisma.item.create({
      data: { ...base, categoryId, nameAr: 'قفازات', nameEn: null },
    });
    expect(await searchTextOf(item.id)).toBe('قفازات');
  });
});

describe('CHECK constraints (integration)', () => {
  let prisma: PrismaService;
  let categoryId: string;
  let itemId: string;
  let userId: string;

  beforeAll(async () => {
    const ref = await Test.createTestingModule({
      imports: [AppConfigModule],
      providers: [PrismaService],
    }).compile();
    prisma = ref.get(PrismaService);
    await prisma.$connect();
  });

  beforeEach(async () => {
    await prisma.stockMovement.deleteMany();
    await prisma.warehouseBatch.deleteMany();
    await prisma.item.deleteMany();
    await prisma.category.deleteMany();
    await prisma.user.deleteMany();

    const c = await prisma.category.create({ data: { nameAr: 'مستهلكات', level: 1 } });
    categoryId = c.id;
    const i = await prisma.item.create({
      data: {
        categoryId,
        nameAr: 'سرنجة',
        unitsPerBox: 100,
        unitLabelAr: 'سرنجة',
        pricePerBox: '1.00',
      },
    });
    itemId = i.id;
    const u = await prisma.user.create({
      data: { username: 'constraint_probe', passwordHash: 'x' },
    });
    userId = u.id;
  });

  afterAll(async () => {
    await prisma.stockMovement.deleteMany();
    await prisma.warehouseBatch.deleteMany();
    await prisma.item.deleteMany();
    await prisma.category.deleteMany();
    await prisma.user.deleteMany();
    await prisma.$disconnect();
  });

  // Prisma cannot express a CHECK and its drift detection cannot see one, so a
  // later `prisma migrate dev` could drop these while reporting success.
  // These tests are what notices.

  it('rejects a category deeper than three levels', async () => {
    await expect(
      prisma.$executeRawUnsafe(
        `INSERT INTO categories (id,"nameAr",level,"sortOrder","isActive","createdAt","updatedAt")
         VALUES (gen_random_uuid(),'عميق',4,0,true,now(),now())`,
      ),
    ).rejects.toThrow();
  });

  it('rejects an item with no name in either language', async () => {
    await expect(
      prisma.$executeRawUnsafe(
        `INSERT INTO items (id,"categoryId","unitsPerBox","unitLabelAr","pricePerBox","isActive","createdAt","updatedAt")
         VALUES (gen_random_uuid(),$1,10,'ق',1.00,true,now(),now())`,
        categoryId,
      ),
    ).rejects.toThrow();
  });

  it('rejects a non-positive box size', async () => {
    await expect(
      prisma.$executeRawUnsafe(
        `INSERT INTO items (id,"nameAr","categoryId","unitsPerBox","unitLabelAr","pricePerBox","isActive","createdAt","updatedAt")
         VALUES (gen_random_uuid(),'س',$1,0,'ق',1.00,true,now(),now())`,
        categoryId,
      ),
    ).rejects.toThrow();
  });

  it('rejects an ADMIN movement that names a client', async () => {
    // The warehouse is clientId IS NULL. Allowing both would reintroduce the
    // "two warehouses" failure the NULL convention exists to prevent.
    await expect(
      prisma.$executeRawUnsafe(
        `INSERT INTO stock_movements (id,"ownerType","clientId","itemId","qtyUnitsDelta",reason,"createdAt")
         VALUES (gen_random_uuid(),'ADMIN',$1,$2,1,'PURCHASE_IN',now())`,
        userId,
        itemId,
      ),
    ).rejects.toThrow();
  });

  it('rejects a CLIENT movement with no client', async () => {
    await expect(
      prisma.$executeRawUnsafe(
        `INSERT INTO stock_movements (id,"ownerType","clientId","itemId","qtyUnitsDelta",reason,"createdAt")
         VALUES (gen_random_uuid(),'CLIENT',NULL,$1,1,'DELIVERY_IN',now())`,
        itemId,
      ),
    ).rejects.toThrow();
  });

  it('accepts a well-formed ADMIN warehouse movement', async () => {
    await expect(
      prisma.$executeRawUnsafe(
        `INSERT INTO stock_movements (id,"ownerType","clientId","itemId","qtyUnitsDelta",reason,"createdAt")
         VALUES (gen_random_uuid(),'ADMIN',NULL,$1,500,'PURCHASE_IN',now())`,
        itemId,
      ),
    ).resolves.toBe(1);
  });

  it('rejects remaining greater than received', async () => {
    await expect(
      prisma.$executeRawUnsafe(
        `INSERT INTO warehouse_batches (id,"itemId","batchNumber","expiryDate","qtyUnitsReceived","qtyUnitsRemaining","receivedAt")
         VALUES (gen_random_uuid(),$1,'B-BAD','2030-01-01',10,99,now())`,
        itemId,
      ),
    ).rejects.toThrow();
  });

  it('stores expiryDate as a calendar date, immune to timezone shift', async () => {
    // As a timestamp at Asia/Baghdad (UTC+3), local midnight 2027-03-01 would
    // persist as 2027-02-28T21:00:00Z and shift every expiry by a day.
    await prisma.$executeRawUnsafe(
      `INSERT INTO warehouse_batches (id,"itemId","batchNumber","expiryDate","qtyUnitsReceived","qtyUnitsRemaining","receivedAt")
       VALUES (gen_random_uuid(),$1,'B-TZ','2027-03-01',10,10,now())`,
      itemId,
    );
    const rows = await prisma.$queryRawUnsafe<{ d: string }[]>(
      `SELECT to_char("expiryDate",'YYYY-MM-DD') AS d FROM warehouse_batches WHERE "batchNumber"='B-TZ'`,
    );
    expect(rows[0].d).toBe('2027-03-01');
  });
});
