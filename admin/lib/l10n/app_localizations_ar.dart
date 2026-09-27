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
}
