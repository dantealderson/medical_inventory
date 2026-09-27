// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Arabic (`ar`).
class AppLocalizationsAr extends AppLocalizations {
  AppLocalizationsAr([String locale = 'ar']) : super(locale);

  @override
  String get appTitle => 'إدارة المخزون الطبي';

  @override
  String get loading => 'جارٍ التحميل...';

  @override
  String get login => 'تسجيل الدخول';

  @override
  String get username => 'اسم المستخدم';

  @override
  String get password => 'كلمة المرور';

  @override
  String get logout => 'تسجيل الخروج';

  @override
  String get usernameRequired => 'اسم المستخدم مطلوب';

  @override
  String get passwordRequired => 'كلمة المرور مطلوبة';

  @override
  String get passwordTooShort => 'كلمة المرور يجب أن تكون 8 أحرف على الأقل';

  @override
  String get pendingAccounts => 'طلبات الحسابات';

  @override
  String get noPendingAccounts => 'لا توجد طلبات جديدة';

  @override
  String get approve => 'موافقة';

  @override
  String get reject => 'رفض';

  @override
  String get suspend => 'إيقاف';

  @override
  String get reactivate => 'إعادة تفعيل';

  @override
  String get resetPassword => 'إعادة تعيين كلمة المرور';

  @override
  String get newPassword => 'كلمة المرور الجديدة';

  @override
  String get cancel => 'إلغاء';

  @override
  String get confirm => 'تأكيد';

  @override
  String get accountDetails => 'تفاصيل الحساب';

  @override
  String get clinicName => 'اسم المختبر';

  @override
  String get status => 'الحالة';

  @override
  String get statusPending => 'قيد المراجعة';

  @override
  String get statusActive => 'مفعّل';

  @override
  String get statusSuspended => 'موقوف';

  @override
  String get statusRejected => 'مرفوض';

  @override
  String get resetPasswordDone =>
      'تم تعيين كلمة المرور الجديدة وإنهاء جميع الجلسات';

  @override
  String get resetPasswordHint =>
      'اقرأ كلمة المرور الجديدة للعميل عبر الهاتف. لن تظهر مرة أخرى.';

  @override
  String get confirmApprove => 'هل تريد الموافقة على هذا الحساب؟';

  @override
  String get confirmReject => 'هل تريد رفض هذا الطلب؟';

  @override
  String get confirmSuspend =>
      'سيتم إنهاء جميع جلسات هذا الحساب فوراً. هل تريد المتابعة؟';

  @override
  String get retry => 'إعادة المحاولة';

  @override
  String get catalog => 'الأقسام والأصناف';

  @override
  String get categories => 'الأقسام';

  @override
  String get items => 'الأصناف';

  @override
  String get batches => 'التشغيلات';

  @override
  String get addCategory => 'إضافة قسم';

  @override
  String get addSubCategory => 'إضافة قسم فرعي';

  @override
  String get addItem => 'إضافة صنف';

  @override
  String get receiveBatch => 'استلام تشغيلة';

  @override
  String get nameArLabel => 'الاسم بالعربية';

  @override
  String get nameEnLabel => 'الاسم بالإنجليزية';

  @override
  String get parentCategory => 'القسم الأعلى';

  @override
  String get noParent => 'قسم رئيسي';

  @override
  String get unitsPerBox => 'عدد الوحدات في العلبة';

  @override
  String get unitLabel => 'اسم الوحدة';

  @override
  String get pricePerBox => 'سعر العلبة';

  @override
  String get minStockBoxes => 'الحد الأدنى (علب)';

  @override
  String get batchNumber => 'رقم التشغيلة';

  @override
  String get expiryDate => 'تاريخ انتهاء الصلاحية';

  @override
  String get quantityBoxes => 'الكمية (علب)';

  @override
  String get inStock => 'المتوفر';

  @override
  String get expiringSoon => 'قارب على الانتهاء';

  @override
  String get expired => 'منتهي الصلاحية';

  @override
  String get noCategories => 'لا توجد أقسام بعد';

  @override
  String get noItems => 'لا توجد أصناف بعد';

  @override
  String get noBatches => 'لا توجد تشغيلات';

  @override
  String get save => 'حفظ';

  @override
  String get delete => 'حذف';

  @override
  String get deactivate => 'إلغاء التفعيل';

  @override
  String get edit => 'تعديل';

  @override
  String get categoryDepthHint => 'ثلاثة مستويات كحد أقصى';

  @override
  String get boxesShort => 'علبة';

  @override
  String get unitsShort => 'وحدة';

  @override
  String get requiredField => 'هذا الحقل مطلوب';

  @override
  String get invalidPrice =>
      'السعر يجب أن يكون رقماً بمنزلتين عشريتين على الأكثر';

  @override
  String get mustBePositive => 'يجب أن يكون رقماً أكبر من صفر';

  @override
  String get nameRequiredOneOf => 'يجب إدخال الاسم بالعربية أو بالإنجليزية';

  @override
  String get expiryMustBeFuture =>
      'تاريخ انتهاء الصلاحية يجب أن يكون في المستقبل';

  @override
  String get pickDate => 'اختر التاريخ';

  @override
  String get itemSaved => 'تم حفظ الصنف';

  @override
  String get categorySaved => 'تم حفظ القسم';

  @override
  String get batchReceived => 'تم تسجيل التشغيلة';
}
