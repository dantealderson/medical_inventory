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

  /// Phase 3 orders: the orders screen title and the app-bar orders button tooltip
  ///
  /// In ar, this message translates to:
  /// **'طلباتي'**
  String get myOrders;

  /// Phase 3 orders: the cart's place-order button
  ///
  /// In ar, this message translates to:
  /// **'إرسال الطلب'**
  String get placeOrder;

  /// Phase 3 orders: label of the optional note sent with the order
  ///
  /// In ar, this message translates to:
  /// **'ملاحظة للمورد (اختياري)'**
  String get orderNote;

  /// Phase 3 orders: empty order history
  ///
  /// In ar, this message translates to:
  /// **'لا توجد طلبات بعد'**
  String get noOrders;

  /// Phase 3 orders: loads the next page of order history
  ///
  /// In ar, this message translates to:
  /// **'عرض المزيد'**
  String get loadMore;

  /// Phase 3 orders: status PLACED
  ///
  /// In ar, this message translates to:
  /// **'بانتظار التأكيد'**
  String get orderStatusPlaced;

  /// Phase 3 orders: status CONFIRMED
  ///
  /// In ar, this message translates to:
  /// **'مؤكد'**
  String get orderStatusConfirmed;

  /// Phase 3 orders: status OUT_FOR_DELIVERY
  ///
  /// In ar, this message translates to:
  /// **'قيد التوصيل'**
  String get orderStatusOutForDelivery;

  /// Phase 3 orders: status DELIVERED
  ///
  /// In ar, this message translates to:
  /// **'تم التسليم'**
  String get orderStatusDelivered;

  /// Phase 3 orders: status CANCELLED
  ///
  /// In ar, this message translates to:
  /// **'ملغى'**
  String get orderStatusCancelled;

  /// Phase 3 orders: a status this app version does not know
  ///
  /// In ar, this message translates to:
  /// **'حالة غير معروفة'**
  String get orderStatusUnknown;

  /// Phase 3 orders: order detail screen title
  ///
  /// In ar, this message translates to:
  /// **'تفاصيل الطلب'**
  String get orderDetails;

  /// Phase 3 orders: label of the cash total collected on delivery
  ///
  /// In ar, this message translates to:
  /// **'المبلغ المستحق عند الاستلام'**
  String get orderTotal;

  /// Phase 3 orders: how many lines an order has, in the history list
  ///
  /// In ar, this message translates to:
  /// **'عدد الأصناف: {count}'**
  String orderLineCount(int count);

  /// Phase 3 orders: timeline step: placed
  ///
  /// In ar, this message translates to:
  /// **'تم إرسال الطلب'**
  String get timelinePlaced;

  /// Phase 3 orders: timeline step: confirmed
  ///
  /// In ar, this message translates to:
  /// **'أكّد المورد الطلب'**
  String get timelineConfirmed;

  /// Phase 3 orders: timeline step: out for delivery
  ///
  /// In ar, this message translates to:
  /// **'خرج الطلب للتوصيل'**
  String get timelineOutForDelivery;

  /// Phase 3 orders: timeline step: delivered
  ///
  /// In ar, this message translates to:
  /// **'تم تسليم الطلب'**
  String get timelineDelivered;

  /// Phase 3 orders: timeline step: cancelled
  ///
  /// In ar, this message translates to:
  /// **'أُلغي الطلب'**
  String get timelineCancelled;

  /// Phase 3 orders: quantity the clinic asked for; qty is already formatted
  ///
  /// In ar, this message translates to:
  /// **'المطلوب: {qty}'**
  String requestedQty(String qty);

  /// Phase 3 orders: quantity the supplier approved; qty is already formatted
  ///
  /// In ar, this message translates to:
  /// **'الموافق عليه: {qty}'**
  String approvedQty(String qty);

  /// Phase 3 orders: quantity actually allocated from stock; qty is already formatted
  ///
  /// In ar, this message translates to:
  /// **'المجهَّز: {qty}'**
  String fulfilledQty(String qty);

  /// Phase 3 orders: explains approved < requested
  ///
  /// In ar, this message translates to:
  /// **'عدّل المورد الكمية التي طلبتها'**
  String get adjustedBySupplierNote;

  /// Phase 3 orders: explains fulfilled < approved; qty is already formatted
  ///
  /// In ar, this message translates to:
  /// **'نقص في المخزون: لم يتوفر {qty}'**
  String shortStockNote(String qty);

  /// Phase 3 orders: cancel button, shown only while the order is waiting for confirmation
  ///
  /// In ar, this message translates to:
  /// **'إلغاء الطلب'**
  String get cancelOrder;

  /// Phase 3 orders: cancel confirmation dialog
  ///
  /// In ar, this message translates to:
  /// **'هل تريد إلغاء هذا الطلب؟'**
  String get cancelOrderQuestion;

  /// Phase 3 orders: dialog button that keeps the order
  ///
  /// In ar, this message translates to:
  /// **'لا، أبقِ الطلب'**
  String get keepOrder;

  /// Phase 3 orders: dialog button that cancels the order
  ///
  /// In ar, this message translates to:
  /// **'نعم، ألغِ الطلب'**
  String get confirmCancelOrder;

  /// Phase 3 orders: confirmation after a cancel
  ///
  /// In ar, this message translates to:
  /// **'تم إلغاء الطلب'**
  String get orderCancelled;

  /// Phase 3 orders: cancelled at PLACED
  ///
  /// In ar, this message translates to:
  /// **'أُلغي الطلب قبل تأكيده.'**
  String get dispositionNotAllocated;

  /// Phase 3 orders: cancelled at CONFIRMED
  ///
  /// In ar, this message translates to:
  /// **'أُلغي الطلب بعد تأكيده وقبل خروجه للتوصيل.'**
  String get dispositionReleasedBeforeDispatch;

  /// Phase 3 orders: cancelled while out for delivery; goods returned
  ///
  /// In ar, this message translates to:
  /// **'أُلغي الطلب وأُعيدت البضاعة إلى المستودع.'**
  String get dispositionReturnedToWarehouse;

  /// Phase 3 orders: cancelled while out for delivery; goods did not come back
  ///
  /// In ar, this message translates to:
  /// **'أُلغي الطلب بعد خروجه للتوصيل.'**
  String get dispositionWrittenOff;

  /// Phase 3 orders: a disposition this app version does not know
  ///
  /// In ar, this message translates to:
  /// **'أُلغي الطلب.'**
  String get dispositionUnknown;

  /// Phase 3 item detail: label of the expiry date of the stock an order would receive now
  ///
  /// In ar, this message translates to:
  /// **'صلاحية الكمية التي ستصلك'**
  String get nextExpiry;

  /// Phase 3 item detail: nothing in stock with enough shelf life to ship
  ///
  /// In ar, this message translates to:
  /// **'غير متوفر حالياً'**
  String get currentlyUnavailable;

  /// Phase 4: the clinic's own inventory, as a home button and a screen title
  ///
  /// In ar, this message translates to:
  /// **'مخزوني'**
  String get myInventory;

  /// Phase 4: My Inventory with nothing on the shelf yet
  ///
  /// In ar, this message translates to:
  /// **'لا توجد أصناف في مخزونك بعد. ستظهر هنا بعد استلام أول طلب.'**
  String get inventoryEmpty;

  /// Phase 4: RED stock badge
  ///
  /// In ar, this message translates to:
  /// **'ناقص'**
  String get stockRed;

  /// Phase 4: RED stock badge when the shelf is empty
  ///
  /// In ar, this message translates to:
  /// **'نفد'**
  String get stockOut;

  /// Phase 4: YELLOW stock badge
  ///
  /// In ar, this message translates to:
  /// **'قليل'**
  String get stockYellow;

  /// Phase 4: GREEN stock badge
  ///
  /// In ar, this message translates to:
  /// **'جيد'**
  String get stockGreen;

  /// Phase 4: UNKNOWN stock badge (no usage data and no minimum)
  ///
  /// In ar, this message translates to:
  /// **'غير محدد'**
  String get stockUnknown;

  /// Phase 4: how many days the stock should last
  ///
  /// In ar, this message translates to:
  /// **'{days, plural, =0{يكفي أقل من يوم} =1{يكفي يوماً واحداً} =2{يكفي يومين} few{يكفي حوالي {days} أيام} many{يكفي حوالي {days} يوماً} other{يكفي حوالي {days} يوم}}'**
  String daysOfCover(int days);

  /// Phase 4: no usage rate yet (spec §7.5)
  ///
  /// In ar, this message translates to:
  /// **'لا توجد بيانات كافية'**
  String get noEstimate;

  /// Phase 4: the usage rate was set by the supplier
  ///
  /// In ar, this message translates to:
  /// **'معدل الاستهلاك حدده المورد'**
  String get sourceManual;

  /// Phase 4: the usage rate was measured between stock counts
  ///
  /// In ar, this message translates to:
  /// **'تقدير من الجرد'**
  String get sourceMeasured;

  /// Phase 4: the usage rate was estimated from purchases
  ///
  /// In ar, this message translates to:
  /// **'تقدير من مشترياتك'**
  String get sourcePurchase;

  /// Phase 4: a held batch that expires soon
  ///
  /// In ar, this message translates to:
  /// **'الدفعة {batch} تنتهي صلاحيتها في {date}'**
  String batchExpiresOn(String batch, String date);

  /// Phase 4: a held batch that has expired
  ///
  /// In ar, this message translates to:
  /// **'الدفعة {batch} منتهية الصلاحية منذ {date}'**
  String batchExpired(String batch, String date);

  /// Phase 4: a batch number in the history
  ///
  /// In ar, this message translates to:
  /// **'الدفعة {batch}'**
  String batchLabel(String batch);

  /// Phase 4: home strip of the clinic's red items
  ///
  /// In ar, this message translates to:
  /// **'أصناف تحتاج إلى طلب'**
  String get lowStockTitle;

  /// Phase 4: opens My Inventory from the home strip
  ///
  /// In ar, this message translates to:
  /// **'عرض الكل'**
  String get seeAll;

  /// Phase 4: an item's history of stock changes
  ///
  /// In ar, this message translates to:
  /// **'سجل الحركة'**
  String get movementHistory;

  /// Phase 4: history reason DELIVERY_IN
  ///
  /// In ar, this message translates to:
  /// **'استلام طلب'**
  String get reasonDeliveryIn;

  /// Phase 4: history reason AUTO_DECREMENT
  ///
  /// In ar, this message translates to:
  /// **'استهلاك تقديري'**
  String get reasonAutoDecrement;

  /// Phase 4: history reason STOCK_COUNT_ADJUST
  ///
  /// In ar, this message translates to:
  /// **'تصحيح بالجرد'**
  String get reasonStockCount;

  /// Phase 4: history reason MANUAL_ADJUST
  ///
  /// In ar, this message translates to:
  /// **'تعديل من المورد'**
  String get reasonManualAdjust;

  /// Phase 4: history reason not otherwise named
  ///
  /// In ar, this message translates to:
  /// **'حركة'**
  String get reasonOther;

  /// Phase 4: the stock count, as a button and a screen title
  ///
  /// In ar, this message translates to:
  /// **'جرد المخزون'**
  String get stockCount;

  /// Phase 4 count: field label for whole boxes
  ///
  /// In ar, this message translates to:
  /// **'علب'**
  String get countBoxes;

  /// Phase 4 count: field label for loose units outside whole boxes
  ///
  /// In ar, this message translates to:
  /// **'{unit} مفردة'**
  String countLooseUnits(String unit);

  /// Phase 4 count: instruction at the top of the count
  ///
  /// In ar, this message translates to:
  /// **'اكتب ما تجده فعلاً على الرف. اترك الصنف فارغاً إذا لم تعدّه.'**
  String get countHint;

  /// Phase 4 count: save button
  ///
  /// In ar, this message translates to:
  /// **'حفظ الجرد'**
  String get saveCount;

  /// Phase 4 count: confirmation before saving
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{سيتم تحديث صنف واحد حسب الجرد. هل تريد المتابعة؟} =2{سيتم تحديث صنفين حسب الجرد. هل تريد المتابعة؟} few{سيتم تحديث {count} أصناف حسب الجرد. هل تريد المتابعة؟} many{سيتم تحديث {count} صنفاً حسب الجرد. هل تريد المتابعة؟} other{سيتم تحديث {count} صنف حسب الجرد. هل تريد المتابعة؟}}'**
  String confirmCount(int count);

  /// Phase 4 count: confirm in the dialog
  ///
  /// In ar, this message translates to:
  /// **'متابعة'**
  String get confirm;

  /// Phase 4 count: cancel in the dialog
  ///
  /// In ar, this message translates to:
  /// **'إلغاء'**
  String get cancel;

  /// Phase 4 count: result title
  ///
  /// In ar, this message translates to:
  /// **'تم حفظ الجرد'**
  String get countSaved;

  /// Phase 4 count: one item before and after
  ///
  /// In ar, this message translates to:
  /// **'كان {before}، الآن {after}'**
  String countWasNow(String before, String after);

  /// Phase 4 count: less than the system believed
  ///
  /// In ar, this message translates to:
  /// **'نقص {qty}'**
  String countLess(String qty);

  /// Phase 4 count: more than the system believed
  ///
  /// In ar, this message translates to:
  /// **'زيادة {qty}'**
  String countMore(String qty);

  /// Phase 4 count: as the system believed
  ///
  /// In ar, this message translates to:
  /// **'بدون تغيير'**
  String get countSame;

  /// Phase 4 count: leaves the result
  ///
  /// In ar, this message translates to:
  /// **'العودة إلى مخزوني'**
  String get backToInventory;

  /// Phase 5: the notification bell tooltip and the centre title
  ///
  /// In ar, this message translates to:
  /// **'الإشعارات'**
  String get notifications;

  /// Phase 5: the centre with nothing in it
  ///
  /// In ar, this message translates to:
  /// **'لا توجد إشعارات'**
  String get noNotifications;

  /// Phase 5: marks every notification read
  ///
  /// In ar, this message translates to:
  /// **'تحديد الكل كمقروء'**
  String get markAllRead;

  /// Phase 5: an unread notification, said in words and not only in weight
  ///
  /// In ar, this message translates to:
  /// **'جديد'**
  String get unreadLabel;

  /// Stop tracking: the button on an item page
  ///
  /// In ar, this message translates to:
  /// **'إيقاف متابعة هذا الصنف'**
  String get stopTracking;

  /// Stop tracking: the confirmation title
  ///
  /// In ar, this message translates to:
  /// **'إيقاف متابعة {item}؟'**
  String stopTrackingQuestion(String item);

  /// Stop tracking: what it does, in plain words
  ///
  /// In ar, this message translates to:
  /// **'لن يظهر هذا الصنف في مخزونك ولن تصلك تنبيهات عنه. سيعود تلقائياً عند استلام طلب جديد منه، ويمكنك إعادته في أي وقت.'**
  String get stopTrackingExplained;

  /// Stop tracking: confirm
  ///
  /// In ar, this message translates to:
  /// **'إيقاف المتابعة'**
  String get confirmStopTracking;

  /// Stop tracking: done
  ///
  /// In ar, this message translates to:
  /// **'تم إيقاف متابعة {item}'**
  String trackingStopped(String item);

  /// Stop tracking: the list at the bottom of My Inventory
  ///
  /// In ar, this message translates to:
  /// **'أصناف أوقفت متابعتها'**
  String get stoppedItemsTitle;

  /// Stop tracking: brings an item back
  ///
  /// In ar, this message translates to:
  /// **'استئناف المتابعة'**
  String get resumeTracking;

  /// Home app bar: the menu that holds log out
  ///
  /// In ar, this message translates to:
  /// **'المزيد'**
  String get more;

  /// Log out: confirmation dialog title
  ///
  /// In ar, this message translates to:
  /// **'تسجيل الخروج؟'**
  String get logoutQuestion;

  /// Log out: confirmation dialog body
  ///
  /// In ar, this message translates to:
  /// **'ستحتاج إلى اسم المستخدم وكلمة المرور للدخول مرة أخرى.'**
  String get logoutExplained;

  /// Log out: dialog button that logs out
  ///
  /// In ar, this message translates to:
  /// **'خروج'**
  String get confirmLogout;

  /// Login: checkbox, ticked by default. Unticked, closing the app signs out
  ///
  /// In ar, this message translates to:
  /// **'إبقني مسجّلاً الدخول على هذا الهاتف'**
  String get keepMeSignedIn;

  /// Category screen: the category is no longer in the catalog
  ///
  /// In ar, this message translates to:
  /// **'هذا القسم لم يعد متوفراً'**
  String get categoryUnavailable;

  /// Login: the server ended the session (account suspended, password reset, or unused too long)
  ///
  /// In ar, this message translates to:
  /// **'انتهت الجلسة، يرجى تسجيل الدخول مرة أخرى'**
  String get sessionEnded;

  /// Stock count: leaving with numbers typed; dialog title
  ///
  /// In ar, this message translates to:
  /// **'تجاهل الجرد؟'**
  String get discardCountQuestion;

  /// Stock count: leaving with numbers typed; dialog body
  ///
  /// In ar, this message translates to:
  /// **'الكميات التي أدخلتها لن تُحفظ.'**
  String get discardCountExplained;

  /// Stock count: dialog button that stays on the count
  ///
  /// In ar, this message translates to:
  /// **'متابعة الجرد'**
  String get keepCounting;

  /// Stock count: dialog button that leaves without saving
  ///
  /// In ar, this message translates to:
  /// **'تجاهل'**
  String get discardCount;

  /// Home search box: the clear button, which brings the categories back
  ///
  /// In ar, this message translates to:
  /// **'مسح البحث'**
  String get clearSearch;

  /// Startup: the server cannot be reached; the session is kept and a retry is offered
  ///
  /// In ar, this message translates to:
  /// **'تعذر الاتصال بالخادم، تحقق من الإنترنت'**
  String get serverUnreachable;
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
