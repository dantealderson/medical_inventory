import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_ar.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('ar')];

  /// Admin application title
  ///
  /// In ar, this message translates to:
  /// **'إدارة المخزون الطبي'**
  String get appTitle;

  /// Generic loading indicator label
  ///
  /// In ar, this message translates to:
  /// **'جارٍ التحميل...'**
  String get loading;

  /// Login button and screen title
  ///
  /// In ar, this message translates to:
  /// **'تسجيل الدخول'**
  String get login;

  /// Username field label
  ///
  /// In ar, this message translates to:
  /// **'اسم المستخدم'**
  String get username;

  /// Password field label
  ///
  /// In ar, this message translates to:
  /// **'كلمة المرور'**
  String get password;

  /// Logout action
  ///
  /// In ar, this message translates to:
  /// **'تسجيل الخروج'**
  String get logout;

  /// Validation: username empty
  ///
  /// In ar, this message translates to:
  /// **'اسم المستخدم مطلوب'**
  String get usernameRequired;

  /// Validation: password empty
  ///
  /// In ar, this message translates to:
  /// **'كلمة المرور مطلوبة'**
  String get passwordRequired;

  /// Validation: password under 8 chars
  ///
  /// In ar, this message translates to:
  /// **'كلمة المرور يجب أن تكون 8 أحرف على الأقل'**
  String get passwordTooShort;

  /// Pending approvals screen title
  ///
  /// In ar, this message translates to:
  /// **'طلبات الحسابات'**
  String get pendingAccounts;

  /// Empty state for the approvals queue
  ///
  /// In ar, this message translates to:
  /// **'لا توجد طلبات جديدة'**
  String get noPendingAccounts;

  /// Approve a pending account
  ///
  /// In ar, this message translates to:
  /// **'موافقة'**
  String get approve;

  /// Reject a pending account
  ///
  /// In ar, this message translates to:
  /// **'رفض'**
  String get reject;

  /// Suspend an active account
  ///
  /// In ar, this message translates to:
  /// **'إيقاف'**
  String get suspend;

  /// Reactivate a suspended account
  ///
  /// In ar, this message translates to:
  /// **'إعادة تفعيل'**
  String get reactivate;

  /// Reset a client's password
  ///
  /// In ar, this message translates to:
  /// **'إعادة تعيين كلمة المرور'**
  String get resetPassword;

  /// New password field label
  ///
  /// In ar, this message translates to:
  /// **'كلمة المرور الجديدة'**
  String get newPassword;

  /// Cancel a dialog
  ///
  /// In ar, this message translates to:
  /// **'إلغاء'**
  String get cancel;

  /// Confirm a dialog
  ///
  /// In ar, this message translates to:
  /// **'تأكيد'**
  String get confirm;

  /// Account detail screen title
  ///
  /// In ar, this message translates to:
  /// **'تفاصيل الحساب'**
  String get accountDetails;

  /// Clinic name label
  ///
  /// In ar, this message translates to:
  /// **'اسم المختبر'**
  String get clinicName;

  /// Account status label
  ///
  /// In ar, this message translates to:
  /// **'الحالة'**
  String get status;

  /// UserStatus PENDING
  ///
  /// In ar, this message translates to:
  /// **'قيد المراجعة'**
  String get statusPending;

  /// UserStatus ACTIVE
  ///
  /// In ar, this message translates to:
  /// **'مفعّل'**
  String get statusActive;

  /// UserStatus SUSPENDED
  ///
  /// In ar, this message translates to:
  /// **'موقوف'**
  String get statusSuspended;

  /// UserStatus REJECTED
  ///
  /// In ar, this message translates to:
  /// **'مرفوض'**
  String get statusRejected;

  /// Confirmation after a password reset
  ///
  /// In ar, this message translates to:
  /// **'تم تعيين كلمة المرور الجديدة وإنهاء جميع الجلسات'**
  String get resetPasswordDone;

  /// Warns the admin the password is shown once
  ///
  /// In ar, this message translates to:
  /// **'اقرأ كلمة المرور الجديدة للعميل عبر الهاتف. لن تظهر مرة أخرى.'**
  String get resetPasswordHint;

  /// Approve confirmation prompt
  ///
  /// In ar, this message translates to:
  /// **'هل تريد الموافقة على هذا الحساب؟'**
  String get confirmApprove;

  /// Reject confirmation prompt
  ///
  /// In ar, this message translates to:
  /// **'هل تريد رفض هذا الطلب؟'**
  String get confirmReject;

  /// Suspend confirmation, warns sessions end
  ///
  /// In ar, this message translates to:
  /// **'سيتم إنهاء جميع جلسات هذا الحساب فوراً. هل تريد المتابعة؟'**
  String get confirmSuspend;

  /// Retry action on an error state
  ///
  /// In ar, this message translates to:
  /// **'إعادة المحاولة'**
  String get retry;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['ar'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'ar':
      return AppLocalizationsAr();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
