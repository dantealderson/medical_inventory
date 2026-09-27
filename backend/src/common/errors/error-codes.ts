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
} as const);

export type ErrorCode = keyof typeof ERROR_CODES;

export interface ErrorEnvelope {
  statusCode: number;
  code: string;
  messageAr: string;
  details?: unknown;
}
