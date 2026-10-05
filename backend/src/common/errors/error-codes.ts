/**
 * Stable machine-readable error codes. The apps switch on `code`; they never
 * parse `messageAr`. Adding a code is safe; renaming one is a breaking change.
 */
export const ERROR_CODES = Object.freeze({
  VALIDATION_FAILED: 'البيانات المدخلة غير صحيحة',
  NOT_FOUND: 'العنصر المطلوب غير موجود',
  UNAUTHORIZED: 'يجب تسجيل الدخول أولاً',
  FORBIDDEN: 'ليس لديك صلاحية لهذا الإجراء',
  CONFLICT: 'تعارض في البيانات',
  INTERNAL_ERROR: 'حدث خطأ غير متوقع، يرجى المحاولة لاحقاً',
  PAYLOAD_TOO_LARGE: 'البيانات المرسلة كبيرة جداً',

  // --- Auth (Phase 1) ---
  USERNAME_TAKEN: 'اسم المستخدم مستخدم بالفعل',
  INVALID_CREDENTIALS: 'اسم المستخدم أو كلمة المرور غير صحيحة',
  // Deliberately distinct from INVALID_CREDENTIALS: a clinic waiting on
  // approval must be told that, not left retyping a correct password. It is
  // only ever reachable after the password verifies, so it cannot be used to
  // discover which usernames exist.
  ACCOUNT_PENDING: 'حسابك قيد المراجعة، يرجى انتظار موافقة الإدارة',
  ACCOUNT_REJECTED: 'تم رفض طلب حسابك، يرجى التواصل مع الإدارة',
  ACCOUNT_SUSPENDED: 'تم إيقاف حسابك، يرجى التواصل مع الإدارة',
  TOKEN_EXPIRED: 'انتهت صلاحية الجلسة، يرجى تسجيل الدخول مرة أخرى',
  TOKEN_INVALID: 'جلسة غير صالحة، يرجى تسجيل الدخول مرة أخرى',

  // --- Catalog & warehouse (Phase 2) ---
  CATEGORY_DEPTH_EXCEEDED: 'لا يمكن إضافة أكثر من ثلاثة مستويات للأقسام',
  CATEGORY_NOT_EMPTY: 'لا يمكن حذف قسم يحتوي على أقسام أو أصناف',
  PARENT_NOT_FOUND: 'القسم الأعلى غير موجود',
  ITEM_NOT_FOUND: 'الصنف غير موجود',
  BOX_SIZE_FROZEN: 'لا يمكن تغيير عدد الوحدات في العلبة بعد استلام تشغيلات لهذا الصنف',
  BATCH_NUMBER_TAKEN: 'رقم التشغيلة مستخدم بالفعل لهذا الصنف بنفس تاريخ الانتهاء',
  BATCH_ALREADY_EXPIRED: 'تاريخ انتهاء الصلاحية يجب أن يكون في المستقبل',
  INVALID_IMAGE: 'الملف ليس صورة صالحة',
  IMAGE_TOO_LARGE: 'حجم الصورة أكبر من الحد المسموح',
  // --- Ordering (Phase 3) ---
  CART_EMPTY: 'السلة فارغة',
  ITEM_UNAVAILABLE: 'هذا الصنف غير متوفر حالياً',
  CART_HAS_UNAVAILABLE_ITEMS:
    'بعض الأصناف في السلة لم تعد متوفرة، يرجى إزالتها ثم المحاولة مجدداً',
  CART_LINE_LIMIT: 'تجاوزت الحد الأقصى للكمية المسموح بها لهذا الصنف',
  CART_LINE_NOT_FOUND: 'الصنف غير موجود في السلة',
  ORDER_NOT_FOUND: 'الطلب غير موجود',
  ORDER_INVALID_TRANSITION: 'لا يمكن تنفيذ هذا الإجراء على الطلب في حالته الحالية',
  ORDER_NOT_CANCELLABLE_BY_CLIENT: 'لا يمكن إلغاء الطلب بعد تأكيده، يرجى التواصل مع الإدارة',
  ORDER_EDIT_INVALID: 'الكمية المعدلة يجب أن تكون بين صفر والكمية المطلوبة',
  ORDER_NOTHING_TO_FULFIL: 'لا تتوفر أي كمية من أصناف هذا الطلب، يرجى إلغاؤه بدلاً من تأكيده',
  DISPOSITION_REQUIRED: 'يجب تحديد مصير البضاعة عند إلغاء طلب خرج للتوصيل',
  DISPOSITION_NOT_APPLICABLE: 'لا يُحدَّد مصير البضاعة إلا عند إلغاء طلب خرج للتوصيل',
  // --- Inventory (Phase 4) ---
  INVENTORY_ITEM_NOT_FOUND: 'الصنف غير موجود في المخزون',
  CLIENT_NOT_FOUND: 'العميل غير موجود',
  // --- Notifications and jobs (Phase 5) ---
  NOTIFICATION_NOT_FOUND: 'الإشعار غير موجود',
  DEVICE_NOT_FOUND: 'الجهاز غير مسجل',
  JOBS_ALREADY_RUNNING: 'التحديث الليلي قيد التشغيل حالياً',
  // --- Deleting an account (Google Play) ---
  WRONG_PASSWORD: 'كلمة المرور غير صحيحة',
  ORDERS_IN_PROGRESS: 'لديك طلبات لم تصل بعد. يمكنك حذف الحساب بعد وصولها أو إلغائها.',
  ACCOUNT_DELETED: 'حذف العميل هذا الحساب، ولا يمكن إعادته',
  ACCOUNT_STATUS_UNCHANGED: 'لا يمكن تنفيذ هذا الإجراء على الحساب في حالته الحالية، حدّث الصفحة',
} as const);

export type ErrorCode = keyof typeof ERROR_CODES;

export interface ErrorEnvelope {
  statusCode: number;
  code: string;
  messageAr: string;
  details?: unknown;
}
