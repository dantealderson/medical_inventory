import { describe, expect, it } from 'vitest';

import { texts } from '../../src/notifications/notification-texts';

describe('notification texts', () => {
  it('tells the admin which clinic placed an order', () => {
    expect(texts.orderPlaced('عيادة النور')).toEqual({
      titleAr: 'طلب جديد من عيادة النور',
      bodyAr: 'بانتظار التأكيد.',
    });
  });

  it('tells the clinic its order was confirmed, and says so plainly when it ships short', () => {
    expect(texts.orderConfirmed(false)).toEqual({
      titleAr: 'تم تأكيد طلبك',
      bodyAr: 'سيتم تجهيز طلبك وإرساله قريباً.',
    });
    expect(texts.orderConfirmed(true)).toEqual({
      titleAr: 'تم تأكيد طلبك مع نقص في بعض الأصناف',
      bodyAr: 'سيتم إرسال الكمية المتوفرة فقط.',
    });
  });

  it('follows the order to the door', () => {
    expect(texts.orderOutForDelivery().titleAr).toBe('طلبك في الطريق إليك');
    expect(texts.orderDelivered()).toEqual({
      titleAr: 'تم توصيل طلبك',
      bodyAr: 'تمت إضافة الأصناف إلى مخزونك.',
    });
  });

  it('gives the clinic the reason for a cancellation when there is one', () => {
    expect(texts.orderCancelledForClient(null)).toEqual({
      titleAr: 'تم إلغاء طلبك',
      bodyAr: 'للاستفسار تواصل مع الإدارة.',
    });
    expect(texts.orderCancelledForClient('نفاد الكمية').bodyAr).toBe('السبب: نفاد الكمية');
  });

  it('tells the admin which clinic cancelled', () => {
    expect(texts.orderCancelledByClient('عيادة النور').titleAr).toBe('ألغى العميل عيادة النور طلبه');
  });

  it('tells an account it was approved or not', () => {
    expect(texts.accountApproved().titleAr).toBe('تمت الموافقة على حسابك');
    expect(texts.accountRejected().titleAr).toBe('لم تتم الموافقة على حسابك');
  });
});
