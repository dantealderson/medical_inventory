/**
 * Every notification's Arabic, in one place. Composed on the server so the
 * apps show exactly what was stored, and plain on purpose: the readers are
 * clinic staff, many of them older, reading on a phone's lock screen.
 */
export interface NotificationText {
  titleAr: string;
  bodyAr: string;
}

export const texts = {
  orderPlaced: (clinic: string): NotificationText => ({
    titleAr: `طلب جديد من ${clinic}`,
    bodyAr: 'بانتظار التأكيد.',
  }),

  orderConfirmed: (short: boolean): NotificationText =>
    short
      ? { titleAr: 'تم تأكيد طلبك مع نقص في بعض الأصناف', bodyAr: 'سيتم إرسال الكمية المتوفرة فقط.' }
      : { titleAr: 'تم تأكيد طلبك', bodyAr: 'سيتم تجهيز طلبك وإرساله قريباً.' },

  orderOutForDelivery: (): NotificationText => ({
    titleAr: 'طلبك في الطريق إليك',
    bodyAr: 'سيصلك الطلب قريباً.',
  }),

  orderDelivered: (): NotificationText => ({
    titleAr: 'تم توصيل طلبك',
    bodyAr: 'تمت إضافة الأصناف إلى مخزونك.',
  }),

  orderCancelledForClient: (reason: string | null): NotificationText => ({
    titleAr: 'تم إلغاء طلبك',
    bodyAr: reason ? `السبب: ${reason}` : 'للاستفسار تواصل مع الإدارة.',
  }),

  /** «العميل» keeps the sentence right whatever the clinic's name. */
  orderCancelledByClient: (clinic: string): NotificationText => ({
    titleAr: `ألغى العميل ${clinic} طلبه`,
    bodyAr: 'لم يعد الطلب بحاجة إلى تجهيز.',
  }),

  accountApproved: (): NotificationText => ({
    titleAr: 'تمت الموافقة على حسابك',
    bodyAr: 'يمكنك الآن تسجيل الدخول والطلب.',
  }),

  accountRejected: (): NotificationText => ({
    titleAr: 'لم تتم الموافقة على حسابك',
    bodyAr: 'للاستفسار تواصل مع الإدارة.',
  }),
};
