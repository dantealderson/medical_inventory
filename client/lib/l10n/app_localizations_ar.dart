// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Arabic (`ar`).
class AppLocalizationsAr extends AppLocalizations {
  AppLocalizationsAr([String locale = 'ar']) : super(locale);

  @override
  String get appTitle => 'المخزون الطبي';

  @override
  String get loading => 'جارٍ التحميل...';

  @override
  String get login => 'تسجيل الدخول';

  @override
  String get username => 'اسم المستخدم';

  @override
  String get password => 'كلمة المرور';

  @override
  String get register => 'إنشاء حساب';

  @override
  String get haveAccountLogin => 'لديك حساب؟ تسجيل الدخول';

  @override
  String get noAccountRegister => 'ليس لديك حساب؟ إنشاء حساب جديد';

  @override
  String get clinicName => 'اسم المختبر';

  @override
  String get contactName => 'اسم المسؤول';

  @override
  String get phone => 'رقم الهاتف';

  @override
  String get address => 'العنوان';

  @override
  String get optional => 'اختياري';

  @override
  String get pendingTitle => 'حسابك قيد المراجعة';

  @override
  String get pendingBody =>
      'سيتم تفعيل حسابك بعد موافقة الإدارة. يرجى التواصل مع الإدارة لأي استفسار.';

  @override
  String get backToLogin => 'العودة لتسجيل الدخول';

  @override
  String get logout => 'تسجيل الخروج';

  @override
  String get usernameRequired => 'اسم المستخدم مطلوب';

  @override
  String get usernameHint => 'أحرف إنجليزية صغيرة وأرقام وشرطة سفلية فقط';

  @override
  String get passwordRequired => 'كلمة المرور مطلوبة';

  @override
  String get passwordTooShort => 'كلمة المرور يجب أن تكون 8 أحرف على الأقل';

  @override
  String get forgotPassword =>
      'نسيت كلمة المرور؟ تواصل مع الإدارة لإعادة تعيينها';

  @override
  String get retry => 'إعادة المحاولة';

  @override
  String get registerSuccess => 'تم إرسال طلبك بنجاح';
}
