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

  /// Client application title
  ///
  /// In ar, this message translates to:
  /// **'المخزون الطبي'**
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

  /// Register button and screen title
  ///
  /// In ar, this message translates to:
  /// **'إنشاء حساب'**
  String get register;

  /// Link from register to login
  ///
  /// In ar, this message translates to:
  /// **'لديك حساب؟ تسجيل الدخول'**
  String get haveAccountLogin;

  /// Link from login to register
  ///
  /// In ar, this message translates to:
  /// **'ليس لديك حساب؟ إنشاء حساب جديد'**
  String get noAccountRegister;

  /// Clinic name field label
  ///
  /// In ar, this message translates to:
  /// **'اسم المختبر'**
  String get clinicName;

  /// Contact person field label
  ///
  /// In ar, this message translates to:
  /// **'اسم المسؤول'**
  String get contactName;

  /// Phone field label, contact use only
  ///
  /// In ar, this message translates to:
  /// **'رقم الهاتف'**
  String get phone;

  /// Address field label
  ///
  /// In ar, this message translates to:
  /// **'العنوان'**
  String get address;

  /// Suffix marking an optional field
  ///
  /// In ar, this message translates to:
  /// **'اختياري'**
  String get optional;

  /// Awaiting admin approval screen title
  ///
  /// In ar, this message translates to:
  /// **'حسابك قيد المراجعة'**
  String get pendingTitle;

  /// Awaiting approval explanation
  ///
  /// In ar, this message translates to:
  /// **'سيتم تفعيل حسابك بعد موافقة الإدارة. يرجى التواصل مع الإدارة لأي استفسار.'**
  String get pendingBody;

  /// Return to login from the pending screen
  ///
  /// In ar, this message translates to:
  /// **'العودة لتسجيل الدخول'**
  String get backToLogin;

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

  /// Validation: username format
  ///
  /// In ar, this message translates to:
  /// **'أحرف إنجليزية صغيرة وأرقام وشرطة سفلية فقط'**
  String get usernameHint;

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

  /// Static text, NOT a button. There is no self-service reset (requirement 17); a tappable control implying otherwise would generate support calls.
  ///
  /// In ar, this message translates to:
  /// **'نسيت كلمة المرور؟ تواصل مع الإدارة لإعادة تعيينها'**
  String get forgotPassword;

  /// Retry action on an error state
  ///
  /// In ar, this message translates to:
  /// **'إعادة المحاولة'**
  String get retry;

  /// Shown after a successful registration
  ///
  /// In ar, this message translates to:
  /// **'تم إرسال طلبك بنجاح'**
  String get registerSuccess;

  /// Phase 2 catalog: search
  ///
  /// In ar, this message translates to:
  /// **'بحث'**
  String get search;

  /// Phase 2 catalog: searchHint
  ///
  /// In ar, this message translates to:
  /// **'ابحث عن صنف...'**
  String get searchHint;

  /// Phase 2 catalog: noResults
  ///
  /// In ar, this message translates to:
  /// **'لا توجد نتائج'**
  String get noResults;

  /// Phase 2 catalog: categories
  ///
  /// In ar, this message translates to:
  /// **'الأقسام'**
  String get categories;

  /// Phase 2 catalog: items
  ///
  /// In ar, this message translates to:
  /// **'الأصناف'**
  String get items;

  /// Phase 2 catalog: noItemsInCategory
  ///
  /// In ar, this message translates to:
  /// **'لا توجد أصناف في هذا القسم'**
  String get noItemsInCategory;

  /// Phase 2 catalog: pricePerBox
  ///
  /// In ar, this message translates to:
  /// **'سعر العلبة'**
  String get pricePerBox;

  /// Phase 2 catalog: unitsPerBox
  ///
  /// In ar, this message translates to:
  /// **'عدد الوحدات في العلبة'**
  String get unitsPerBox;

  /// Phase 2 catalog: boxesShort
  ///
  /// In ar, this message translates to:
  /// **'علبة'**
  String get boxesShort;

  /// Phase 2 catalog: home
  ///
  /// In ar, this message translates to:
  /// **'الرئيسية'**
  String get home;

  /// Phase 2 catalog: back
  ///
  /// In ar, this message translates to:
  /// **'رجوع'**
  String get back;

  /// Phase 2 catalog: noCategoriesYet
  ///
  /// In ar, this message translates to:
  /// **'لم تتم إضافة أقسام بعد'**
  String get noCategoriesYet;

  /// Phase 2 catalog: searchFailed
  ///
  /// In ar, this message translates to:
  /// **'تعذر البحث، حاول مرة أخرى'**
  String get searchFailed;

  /// Phase 2 catalog: matchingCategories
  ///
  /// In ar, this message translates to:
  /// **'أقسام مطابقة'**
  String get matchingCategories;

  /// Phase 2 catalog: matchingItems
  ///
  /// In ar, this message translates to:
  /// **'أصناف مطابقة'**
  String get matchingItems;

  /// Phase 3 cart: the cart screen title and the app-bar cart button tooltip
  ///
  /// In ar, this message translates to:
  /// **'السلة'**
  String get cart;

  /// Phase 3 cart: screen-reader label of the + button (it shows no text)
  ///
  /// In ar, this message translates to:
  /// **'أضف {name} إلى السلة'**
  String addToCart(String name);

  /// Phase 3 cart: confirmation after the + button added one box
  ///
  /// In ar, this message translates to:
  /// **'تمت إضافة {name} إلى السلة'**
  String addedToCart(String name);

  /// Phase 3 cart: empty state
  ///
  /// In ar, this message translates to:
  /// **'السلة فارغة'**
  String get cartEmpty;

  /// Phase 3 cart: a line whose item was deactivated after it was added
  ///
  /// In ar, this message translates to:
  /// **'هذا الصنف لم يعد متوفراً، يرجى إزالته من السلة'**
  String get itemUnavailable;

  /// Phase 3 cart: tooltip of the + stepper on a cart line
  ///
  /// In ar, this message translates to:
  /// **'زيادة الكمية'**
  String get increaseQty;

  /// Phase 3 cart: tooltip of the - stepper on a cart line; at one box it removes the line
  ///
  /// In ar, this message translates to:
  /// **'إنقاص الكمية'**
  String get decreaseQty;

  /// Phase 3 cart: label of the grand total
  ///
  /// In ar, this message translates to:
  /// **'المجموع'**
  String get cartTotal;
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
