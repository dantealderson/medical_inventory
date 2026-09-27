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
} as const);

export type ErrorCode = keyof typeof ERROR_CODES;

export interface ErrorEnvelope {
  statusCode: number;
  code: string;
  messageAr: string;
  details?: unknown;
}
