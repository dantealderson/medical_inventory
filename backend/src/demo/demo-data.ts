import { MovementReason } from '@prisma/client';

import { addDaysIso, businessDateOf } from '../common/business-date';
import type { PrismaService } from '../prisma/prisma.service';

/**
 * Demo data for a fresh database, so a hosted copy can be tried at once:
 * a catalogue with stock, two approved clinics and one waiting for approval,
 * delivered history, and a shelf that is red, yellow and green.
 *
 * Everything goes through the real API, so every rule and every ledger row is
 * exactly as in real use. The only direct writes move history into the past
 * (a delivery 40 days ago, a count 30 days ago), the way the full-loop test
 * does, because a measured usage rate needs time between two counts.
 */

interface DemoItem {
  code: string;
  nameAr: string;
  nameEn: string;
  unitsPerBox: number;
  unitLabelAr: string;
  pricePerBox: string;
  minQtyBoxes?: number;
  /** Each batch: days until it expires, and boxes received. */
  batches: Array<[expiresInDays: number, boxes: number]>;
}

interface DemoCategory {
  nameAr: string;
  nameEn: string;
  children: Array<{ nameAr: string; nameEn: string; items: DemoItem[] }>;
}

const CATALOGUE: DemoCategory[] = [
  {
    nameAr: 'مستهلكات طبية',
    nameEn: 'Medical consumables',
    children: [
      {
        nameAr: 'سرنجات',
        nameEn: 'Syringes',
        items: [
          { code: 'SYR5', nameAr: 'سرنجة 5 مل', nameEn: 'Syringe 5 ml', unitsPerBox: 100, unitLabelAr: 'سرنجة', pricePerBox: '12500', minQtyBoxes: 2, batches: [[400, 30], [200, 20]] },
          { code: 'SYR10', nameAr: 'سرنجة 10 مل', nameEn: 'Syringe 10 ml', unitsPerBox: 100, unitLabelAr: 'سرنجة', pricePerBox: '15000', batches: [[365, 20]] },
        ],
      },
      {
        nameAr: 'قفازات',
        nameEn: 'Gloves',
        items: [
          { code: 'GLVM', nameAr: 'قفازات طبية مقاس M', nameEn: 'Examination gloves M', unitsPerBox: 100, unitLabelAr: 'قفاز', pricePerBox: '6000', minQtyBoxes: 3, batches: [[300, 40]] },
          { code: 'GLVS', nameAr: 'قفازات معقمة', nameEn: 'Sterile gloves', unitsPerBox: 50, unitLabelAr: 'زوج', pricePerBox: '9500', batches: [[250, 15]] },
        ],
      },
      {
        nameAr: 'شاش وضمادات',
        nameEn: 'Gauze and dressings',
        items: [
          { code: 'GAU', nameAr: 'شاش معقم 10×10', nameEn: 'Sterile gauze 10x10', unitsPerBox: 100, unitLabelAr: 'قطعة', pricePerBox: '4250', batches: [[500, 25]] },
          { code: 'TAPE', nameAr: 'لاصق طبي', nameEn: 'Medical tape', unitsPerBox: 12, unitLabelAr: 'بكرة', pricePerBox: '7000', batches: [[600, 10]] },
          { code: 'BND', nameAr: 'ضماد مرن', nameEn: 'Elastic bandage', unitsPerBox: 10, unitLabelAr: 'لفافة', pricePerBox: '5500', batches: [[700, 12]] },
        ],
      },
    ],
  },
  {
    nameAr: 'أدوية',
    nameEn: 'Medicines',
    children: [
      {
        nameAr: 'مسكنات',
        nameEn: 'Painkillers',
        items: [
          { code: 'PARA', nameAr: 'باراسيتامول 500 ملغ', nameEn: 'Paracetamol 500 mg', unitsPerBox: 100, unitLabelAr: 'حبة', pricePerBox: '3000', batches: [[330, 30]] },
          // One batch about to expire, for the dashboard's expiry list.
          { code: 'IBU', nameAr: 'إيبوبروفين 400 ملغ', nameEn: 'Ibuprofen 400 mg', unitsPerBox: 50, unitLabelAr: 'حبة', pricePerBox: '4500', batches: [[25, 6], [400, 20]] },
        ],
      },
      {
        nameAr: 'مضادات حيوية',
        nameEn: 'Antibiotics',
        items: [
          { code: 'AMOX', nameAr: 'أموكسيسيلين 500 ملغ', nameEn: 'Amoxicillin 500 mg', unitsPerBox: 20, unitLabelAr: 'كبسولة', pricePerBox: '5750', minQtyBoxes: 5, batches: [[180, 25]] },
        ],
      },
    ],
  },
  {
    nameAr: 'أجهزة',
    nameEn: 'Devices',
    children: [
      {
        nameAr: 'أجهزة قياس',
        nameEn: 'Measuring devices',
        items: [
          { code: 'BP', nameAr: 'جهاز قياس ضغط', nameEn: 'Blood pressure monitor', unitsPerBox: 1, unitLabelAr: 'جهاز', pricePerBox: '35000', batches: [[1500, 8]] },
          { code: 'THERM', nameAr: 'مقياس حرارة رقمي', nameEn: 'Digital thermometer', unitsPerBox: 1, unitLabelAr: 'جهاز', pricePerBox: '8000', batches: [[1200, 15]] },
          { code: 'GLUC', nameAr: 'أشرطة قياس السكر', nameEn: 'Glucose test strips', unitsPerBox: 50, unitLabelAr: 'شريط', pricePerBox: '11000', minQtyBoxes: 2, batches: [[120, 20]] },
        ],
      },
    ],
  },
];

const CLINICS = [
  { username: 'clinic_alnoor', clinicName: 'عيادة النور', phone: '07701234567', address: 'بغداد - الكرادة', approved: true },
  { username: 'clinic_alshifa', clinicName: 'مجمع الشفاء الطبي', phone: '07801234567', address: 'البصرة - العشار', approved: true },
  { username: 'lab_alamal', clinicName: 'مختبر الأمل', phone: '07501234567', address: 'أربيل', approved: false },
] as const;

export interface DemoResult {
  clinics: Array<{ username: string; clinicName: string; approved: boolean }>;
}

const DAY = 86_400_000;
const daysAgo = (n: number) => new Date(Date.now() - n * DAY);

/** A small JSON client for the running API. */
class Api {
  constructor(
    private readonly baseUrl: string,
    private readonly token?: string,
  ) {}

  async call<T = { id: string }>(method: string, path: string, body?: unknown): Promise<T> {
    const res = await fetch(`${this.baseUrl}${path}`, {
      method,
      headers: {
        'content-type': 'application/json',
        ...(this.token ? { authorization: `Bearer ${this.token}` } : {}),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    if (!res.ok) throw new Error(`${method} ${path} answered ${res.status}: ${text}`);
    return (text ? JSON.parse(text) : null) as T;
  }

  static async signIn(baseUrl: string, username: string, password: string): Promise<Api> {
    const { accessToken } = await new Api(baseUrl).call<{ accessToken: string }>(
      'POST',
      '/auth/login',
      { username, password },
    );
    return new Api(baseUrl, accessToken);
  }
}

/**
 * Fills an empty catalogue with demo data through the API at [baseUrl]
 * (ending in `/api/v1`). [admin] must be an existing admin account. Every
 * demo clinic gets [clinicPassword]. Refuses a database that already has a
 * catalogue, before changing anything.
 */
export async function seedDemo(
  baseUrl: string,
  prisma: PrismaService,
  admin: { username: string; password: string },
  clinicPassword: string,
): Promise<DemoResult> {
  if ((await prisma.item.count()) > 0 || (await prisma.category.count()) > 0) {
    throw new Error('Demo data needs an empty catalogue, and this database already has one.');
  }

  const timeZone = process.env.BUSINESS_TIMEZONE ?? 'Asia/Baghdad';
  const today = businessDateOf(new Date(), timeZone);
  const asAdmin = await Api.signIn(baseUrl, admin.username, admin.password);

  // The catalogue and the warehouse.
  const itemId = new Map<string, string>();
  for (const top of CATALOGUE) {
    const parent = await asAdmin.call('POST', '/admin/categories', {
      nameAr: top.nameAr,
      nameEn: top.nameEn,
    });
    for (const sub of top.children) {
      const category = await asAdmin.call('POST', '/admin/categories', {
        nameAr: sub.nameAr,
        nameEn: sub.nameEn,
        parentId: parent.id,
      });
      for (const item of sub.items) {
        const created = await asAdmin.call('POST', '/admin/items', {
          categoryId: category.id,
          nameAr: item.nameAr,
          nameEn: item.nameEn,
          unitsPerBox: item.unitsPerBox,
          unitLabelAr: item.unitLabelAr,
          pricePerBox: item.pricePerBox,
          minQtyBoxes: item.minQtyBoxes,
        });
        itemId.set(item.code, created.id);
        for (const [i, [expiresInDays, boxes]] of item.batches.entries()) {
          await asAdmin.call('POST', '/admin/batches', {
            itemId: created.id,
            batchNumber: `${item.code}-${i + 1}`,
            expiryDate: addDaysIso(today, expiresInDays),
            qtyBoxes: boxes,
          });
        }
      }
    }
  }
  const id = (code: string) => itemId.get(code)!;

  // The clinics.
  for (const clinic of CLINICS) {
    const user = await new Api(baseUrl).call('POST', '/auth/register', {
      username: clinic.username,
      password: clinicPassword,
      clinicName: clinic.clinicName,
      phone: clinic.phone,
      address: clinic.address,
    });
    if (clinic.approved) await asAdmin.call('POST', `/admin/users/${user.id}/approve`, {});
  }
  const alnoor = await Api.signIn(baseUrl, CLINICS[0].username, clinicPassword);
  const alshifa = await Api.signIn(baseUrl, CLINICS[1].username, clinicPassword);
  const alnoorId = (
    await prisma.user.findUniqueOrThrow({ where: { username: CLINICS[0].username } })
  ).id;

  /** A clinic orders [lines]; the admin then takes it through [steps]. */
  async function order(
    clinic: Api,
    lines: Array<[code: string, boxes: number]>,
    steps: Array<'confirm' | 'dispatch' | 'deliver'>,
  ): Promise<string> {
    for (const [code, qtyBoxes] of lines) {
      await clinic.call('POST', '/cart/lines', { itemId: id(code), qtyBoxes });
    }
    const placed = await clinic.call('POST', '/orders', {});
    for (const step of steps) await asAdmin.call('POST', `/admin/orders/${placed.id}/${step}`, {});
    return placed.id;
  }

  // Al-Noor: a delivery 40 days ago, then two counts 30 days apart. Syringes
  // went fast (red), paracetamol steadily (yellow), gloves and gauze slowly.
  const delivered = await order(alnoor, [['SYR5', 10], ['GLVM', 5], ['PARA', 3], ['GAU', 2]], [
    'confirm',
    'dispatch',
    'deliver',
  ]);
  // A count backdated before the delivery would count the delivered units as
  // consumption, so the delivery moves further back first.
  await prisma.stockMovement.updateMany({
    where: { clientId: alnoorId, reason: MovementReason.DELIVERY_IN },
    data: { createdAt: daysAgo(40) },
  });
  await prisma.order.update({
    where: { id: delivered },
    data: { placedAt: daysAgo(41), confirmedAt: daysAgo(41), dispatchedAt: daysAgo(40), deliveredAt: daysAgo(40) },
  });
  const first = await alnoor.call('POST', '/inventory/counts', {
    lines: [
      { itemId: id('SYR5'), boxes: 8, units: 0 },
      { itemId: id('GLVM'), boxes: 4, units: 0 },
      { itemId: id('PARA'), boxes: 2, units: 50 },
      { itemId: id('GAU'), boxes: 1, units: 80 },
    ],
  });
  await prisma.stockCount.update({ where: { id: first.id }, data: { countedAt: daysAgo(30) } });
  await alnoor.call('POST', '/inventory/counts', {
    lines: [
      { itemId: id('SYR5'), boxes: 1, units: 50 }, // 650 used in 30 days: about 7 days left
      { itemId: id('GLVM'), boxes: 3, units: 0 },
      { itemId: id('PARA'), boxes: 0, units: 70 }, // 180 used: about 12 days left
      { itemId: id('GAU'), boxes: 1, units: 70 },
    ],
  });
  // Al-Noor reorders the red syringes: waiting for the admin to confirm.
  await order(alnoor, [['SYR5', 5]], []);

  // Al-Shifa: a delivery today, and an order confirmed but not yet sent.
  await order(alshifa, [['GLVS', 2], ['THERM', 1]], ['confirm', 'dispatch', 'deliver']);
  await order(alshifa, [['BND', 3], ['AMOX', 2]], ['confirm']);

  // The nightly run: estimates, alerts, expiry warnings and hot deals.
  await asAdmin.call('POST', '/admin/jobs/nightly', {});

  return {
    clinics: CLINICS.map(({ username, clinicName, approved }) => ({ username, clinicName, approved })),
  };
}
