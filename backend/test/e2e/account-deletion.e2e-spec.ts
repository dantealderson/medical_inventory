import type { INestApplication } from '@nestjs/common';
import { NotificationType, OrderStatus, Role, UserStatus } from '@prisma/client';
import request from 'supertest';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { PrismaService } from '../../src/prisma/prisma.service';
import { createCatalogItem, createPlacedOrder } from '../helpers/fixtures';
import { authed, bootApp, makeUser, TEST_PASSWORD } from '../helpers/http';
import { resetDb } from '../helpers/reset-db';

/**
 * A clinic deleting its own account from the app (a Google Play rule). Its
 * personal details go at once; its orders and stock history stay, under the
 * clinic's name, as the supplier's business records.
 */
describe('Deleting an account (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let admin: { id: string; token: string };
  let clinic: { id: string; token: string };

  const http = () => request(app.getHttpServer());
  const deleteAccount = (token: string, password = TEST_PASSWORD) =>
    authed(app, token).post('/api/v1/auth/delete-account').send({ password });

  beforeAll(async () => {
    ({ app, prisma } = await bootApp());
  });

  beforeEach(async () => {
    await resetDb(prisma);
    admin = await makeUser(app, prisma, 'the_admin', Role.ADMIN);
    clinic = await makeUser(app, prisma, 'clinic_noor', Role.CLIENT, {
      clinicName: 'عيادة النور',
      phone: '07701234567',
      address: 'بغداد - المنصور',
    });
    await prisma.user.update({ where: { id: clinic.id }, data: { contactName: 'د. سارة' } });
  });

  afterAll(async () => {
    await resetDb(prisma);
    await app.close();
  });

  it('erases the personal details at once and keeps the clinic name', async () => {
    await deleteAccount(clinic.token).expect(204);

    const user = await prisma.user.findUniqueOrThrow({ where: { id: clinic.id } });
    expect(user.deletedAt).not.toBeNull();
    expect(user.status).toBe(UserStatus.SUSPENDED);
    expect(user.username).toMatch(/^deleted-/);
    expect(user).toMatchObject({ contactName: null, phone: null, address: null, clinicName: 'عيادة النور' });
  });

  it('ends every session and the old username and password no longer sign in', async () => {
    await deleteAccount(clinic.token).expect(204);

    expect(await prisma.refreshToken.count({ where: { userId: clinic.id, revokedAt: null } })).toBe(0);
    await http()
      .post('/api/v1/auth/login')
      .send({ username: 'clinic_noor', password: TEST_PASSWORD })
      .expect(401);
  });

  it('frees the username for a new registration', async () => {
    await deleteAccount(clinic.token).expect(204);

    await http()
      .post('/api/v1/auth/register')
      .send({ username: 'clinic_noor', password: TEST_PASSWORD })
      .expect(201);
  });

  it('forgets the phones, the cart and the notifications', async () => {
    await authed(app, clinic.token)
      .post('/api/v1/devices')
      .send({ fcmToken: 'tok-1', platform: 'android' })
      .expect(204);
    await prisma.cart.create({ data: { clientId: clinic.id } });
    await prisma.notification.create({
      data: { recipientUserId: clinic.id, type: NotificationType.ADMIN_BROADCAST, titleAr: 'عطلة', bodyAr: '-' },
    });

    await deleteAccount(clinic.token).expect(204);

    expect(await prisma.deviceToken.count({ where: { userId: clinic.id } })).toBe(0);
    expect(await prisma.cart.count({ where: { clientId: clinic.id } })).toBe(0);
    expect(await prisma.notification.count({ where: { recipientUserId: clinic.id } })).toBe(0);
  });

  it('keeps past orders and stock history, and stops tracking its stock', async () => {
    const { itemId, unitsPerBox } = await createCatalogItem(prisma);
    const { orderId } = await createPlacedOrder(prisma, {
      clientId: clinic.id,
      lines: [{ itemId, qtyBoxes: 1, unitsPerBox }],
    });
    const at = new Date();
    await prisma.order.update({
      where: { id: orderId },
      data: { status: OrderStatus.DELIVERED, confirmedAt: at, dispatchedAt: at, deliveredAt: at },
    });
    await prisma.clientInventoryItem.create({ data: { clientId: clinic.id, itemId, qtyUnits: 40 } });

    await deleteAccount(clinic.token).expect(204);

    const order = await prisma.order.findUniqueOrThrow({ where: { id: orderId } });
    expect(order.totalAmount.toString()).toBe('10');
    // The copies of the address and phone the order took are personal details too.
    expect(order).toMatchObject({ addressSnapshot: null, phoneSnapshot: null });
    const row = await prisma.clientInventoryItem.findUniqueOrThrow({
      where: { clientId_itemId: { clientId: clinic.id, itemId } },
    });
    expect(row.qtyUnits).toBe(40);
    expect(row.trackingStoppedAt).not.toBeNull();
  });

  it('tells the admins and writes the audit log, without the erased details', async () => {
    await deleteAccount(clinic.token).expect(204);

    const note = await prisma.notification.findFirstOrThrow({ where: { recipientUserId: admin.id } });
    expect(note.type).toBe(NotificationType.ACCOUNT_DELETED);
    expect(note.titleAr).toContain('عيادة النور');

    const audit = await prisma.auditLog.findFirstOrThrow({ where: { action: 'ACCOUNT_DELETED' } });
    expect(audit).toMatchObject({ actorUserId: clinic.id, entityType: 'user', entityId: clinic.id });
    expect(JSON.stringify(audit)).not.toContain('07701234567');
  });

  it('refuses a wrong password and changes nothing', async () => {
    const res = await deleteAccount(clinic.token, 'not-my-password').expect(403);

    expect(res.body.code).toBe('WRONG_PASSWORD');
    const user = await prisma.user.findUniqueOrThrow({ where: { id: clinic.id } });
    expect(user).toMatchObject({ username: 'clinic_noor', deletedAt: null, status: UserStatus.ACTIVE });
  });

  it('refuses while an order has not arrived yet', async () => {
    const { itemId, unitsPerBox } = await createCatalogItem(prisma);
    await createPlacedOrder(prisma, { clientId: clinic.id, lines: [{ itemId, qtyBoxes: 1, unitsPerBox }] });

    const res = await deleteAccount(clinic.token).expect(409);

    expect(res.body.code).toBe('ORDERS_IN_PROGRESS');
    expect((await prisma.user.findUniqueOrThrow({ where: { id: clinic.id } })).deletedAt).toBeNull();
  });

  it('is for clinics only: an admin cannot delete itself this way', async () => {
    await deleteAccount(admin.token).expect(403);
  });

  it('a deleted account cannot be reactivated or given a new password', async () => {
    await deleteAccount(clinic.token).expect(204);
    const asAdmin = authed(app, admin.token);

    const reactivate = await asAdmin.post(`/api/v1/admin/users/${clinic.id}/reactivate`).expect(409);
    expect(reactivate.body.code).toBe('ACCOUNT_DELETED');
    await asAdmin
      .post(`/api/v1/admin/users/${clinic.id}/reset-password`)
      .send({ newPassword: 'anotherpass1' })
      .expect(409);
  });

  it('the admin can delete it for a clinic that asks without the app', async () => {
    await authed(app, admin.token).post(`/api/v1/admin/users/${clinic.id}/delete`).expect(204);

    const user = await prisma.user.findUniqueOrThrow({ where: { id: clinic.id } });
    expect(user).toMatchObject({ phone: null, address: null, contactName: null, clinicName: 'عيادة النور' });
    expect(user.deletedAt).not.toBeNull();
    const audit = await prisma.auditLog.findFirstOrThrow({ where: { action: 'ACCOUNT_DELETED' } });
    expect(audit.actorUserId).toBe(admin.id);
    // The admin did it, so the admins are not told about it.
    expect(await prisma.notification.count({ where: { recipientUserId: admin.id } })).toBe(0);
  });

  it('the admin cannot delete an admin, or a clinic with an order on its way', async () => {
    const asAdmin = authed(app, admin.token);
    await asAdmin.post(`/api/v1/admin/users/${admin.id}/delete`).expect(403);

    const { itemId, unitsPerBox } = await createCatalogItem(prisma);
    await createPlacedOrder(prisma, { clientId: clinic.id, lines: [{ itemId, qtyBoxes: 1, unitsPerBox }] });
    const res = await asAdmin.post(`/api/v1/admin/users/${clinic.id}/delete`).expect(409);
    expect(res.body.code).toBe('ORDERS_IN_PROGRESS');
  });

  it('the admin sees when the clinic deleted its account', async () => {
    await deleteAccount(clinic.token).expect(204);

    const res = await authed(app, admin.token).get('/api/v1/admin/users').query({ status: 'SUSPENDED' }).expect(200);
    expect(res.body.items[0]).toMatchObject({ id: clinic.id, clinicName: 'عيادة النور' });
    expect(res.body.items[0].deletedAt).toEqual(expect.any(String));
  });
});
