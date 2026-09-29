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

  /// Phase 2 catalog: catalog
  ///
  /// In ar, this message translates to:
  /// **'الأقسام والأصناف'**
  String get catalog;

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

  /// Phase 2 catalog: batches
  ///
  /// In ar, this message translates to:
  /// **'التشغيلات'**
  String get batches;

  /// Phase 2 catalog: addCategory
  ///
  /// In ar, this message translates to:
  /// **'إضافة قسم'**
  String get addCategory;

  /// Phase 2 catalog: addSubCategory
  ///
  /// In ar, this message translates to:
  /// **'إضافة قسم فرعي'**
  String get addSubCategory;

  /// Phase 2 catalog: addItem
  ///
  /// In ar, this message translates to:
  /// **'إضافة صنف'**
  String get addItem;

  /// Phase 2 catalog: receiveBatch
  ///
  /// In ar, this message translates to:
  /// **'استلام تشغيلة'**
  String get receiveBatch;

  /// Phase 2 catalog: nameArLabel
  ///
  /// In ar, this message translates to:
  /// **'الاسم بالعربية'**
  String get nameArLabel;

  /// Phase 2 catalog: nameEnLabel
  ///
  /// In ar, this message translates to:
  /// **'الاسم بالإنجليزية'**
  String get nameEnLabel;

  /// Phase 2 catalog: parentCategory
  ///
  /// In ar, this message translates to:
  /// **'القسم الأعلى'**
  String get parentCategory;

  /// Phase 2 catalog: noParent
  ///
  /// In ar, this message translates to:
  /// **'قسم رئيسي'**
  String get noParent;

  /// Phase 2 catalog: unitsPerBox
  ///
  /// In ar, this message translates to:
  /// **'عدد الوحدات في العلبة'**
  String get unitsPerBox;

  /// Phase 2 catalog: unitLabel
  ///
  /// In ar, this message translates to:
  /// **'اسم الوحدة'**
  String get unitLabel;

  /// Phase 2 catalog: pricePerBox
  ///
  /// In ar, this message translates to:
  /// **'سعر العلبة'**
  String get pricePerBox;

  /// Phase 2 catalog: minStockBoxes
  ///
  /// In ar, this message translates to:
  /// **'الحد الأدنى (علب)'**
  String get minStockBoxes;

  /// Phase 2 catalog: batchNumber
  ///
  /// In ar, this message translates to:
  /// **'رقم التشغيلة'**
  String get batchNumber;

  /// Phase 2 catalog: expiryDate
  ///
  /// In ar, this message translates to:
  /// **'تاريخ انتهاء الصلاحية'**
  String get expiryDate;

  /// Phase 2 catalog: quantityBoxes
  ///
  /// In ar, this message translates to:
  /// **'الكمية (علب)'**
  String get quantityBoxes;

  /// Phase 2 catalog: inStock
  ///
  /// In ar, this message translates to:
  /// **'المتوفر'**
  String get inStock;

  /// Phase 2 catalog: expiringSoon
  ///
  /// In ar, this message translates to:
  /// **'قارب على الانتهاء'**
  String get expiringSoon;

  /// Phase 2 catalog: expired
  ///
  /// In ar, this message translates to:
  /// **'منتهي الصلاحية'**
  String get expired;

  /// Phase 2 catalog: noCategories
  ///
  /// In ar, this message translates to:
  /// **'لا توجد أقسام بعد'**
  String get noCategories;

  /// Phase 2 catalog: noItems
  ///
  /// In ar, this message translates to:
  /// **'لا توجد أصناف بعد'**
  String get noItems;

  /// Phase 2 catalog: noBatches
  ///
  /// In ar, this message translates to:
  /// **'لا توجد تشغيلات'**
  String get noBatches;

  /// Phase 2 catalog: save
  ///
  /// In ar, this message translates to:
  /// **'حفظ'**
  String get save;

  /// Phase 2 catalog: delete
  ///
  /// In ar, this message translates to:
  /// **'حذف'**
  String get delete;

  /// Phase 2 catalog: deactivate
  ///
  /// In ar, this message translates to:
  /// **'إلغاء التفعيل'**
  String get deactivate;

  /// Phase 2 catalog: edit
  ///
  /// In ar, this message translates to:
  /// **'تعديل'**
  String get edit;

  /// Phase 2 catalog: categoryDepthHint
  ///
  /// In ar, this message translates to:
  /// **'ثلاثة مستويات كحد أقصى'**
  String get categoryDepthHint;

  /// Phase 2 catalog: boxesShort
  ///
  /// In ar, this message translates to:
  /// **'علبة'**
  String get boxesShort;

  /// Phase 2 catalog: unitsShort
  ///
  /// In ar, this message translates to:
  /// **'وحدة'**
  String get unitsShort;

  /// Phase 2 catalog: requiredField
  ///
  /// In ar, this message translates to:
  /// **'هذا الحقل مطلوب'**
  String get requiredField;

  /// Phase 2 catalog: invalidPrice
  ///
  /// In ar, this message translates to:
  /// **'السعر يجب أن يكون رقماً بمنزلتين عشريتين على الأكثر'**
  String get invalidPrice;

  /// Phase 2 catalog: mustBePositive
  ///
  /// In ar, this message translates to:
  /// **'يجب أن يكون رقماً أكبر من صفر'**
  String get mustBePositive;

  /// Phase 2 catalog: nameRequiredOneOf
  ///
  /// In ar, this message translates to:
  /// **'يجب إدخال الاسم بالعربية أو بالإنجليزية'**
  String get nameRequiredOneOf;

  /// Phase 2 catalog: expiryMustBeFuture
  ///
  /// In ar, this message translates to:
  /// **'تاريخ انتهاء الصلاحية يجب أن يكون في المستقبل'**
  String get expiryMustBeFuture;

  /// Phase 2 catalog: pickDate
  ///
  /// In ar, this message translates to:
  /// **'اختر التاريخ'**
  String get pickDate;

  /// Phase 2 catalog: itemSaved
  ///
  /// In ar, this message translates to:
  /// **'تم حفظ الصنف'**
  String get itemSaved;

  /// Phase 2 catalog: categorySaved
  ///
  /// In ar, this message translates to:
  /// **'تم حفظ القسم'**
  String get categorySaved;

  /// Phase 2 catalog: batchReceived
  ///
  /// In ar, this message translates to:
  /// **'تم تسجيل التشغيلة'**
  String get batchReceived;

  /// Phase 3 orders: tab label and queue title
  ///
  /// In ar, this message translates to:
  /// **'الطلبات'**
  String get orders;

  /// Phase 3 orders: detail screen title
  ///
  /// In ar, this message translates to:
  /// **'تفاصيل الطلب'**
  String get orderDetails;

  /// Phase 3 orders: empty queue for the chosen status
  ///
  /// In ar, this message translates to:
  /// **'لا توجد طلبات بهذه الحالة'**
  String get noOrders;

  /// Phase 3 orders: the queue has more than one page
  ///
  /// In ar, this message translates to:
  /// **'توجد طلبات أخرى غير معروضة هنا'**
  String get ordersNotAllShown;

  /// Phase 3 orders: filter chip for every status
  ///
  /// In ar, this message translates to:
  /// **'الكل'**
  String get allStatuses;

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

  /// Phase 3 orders: placement timestamp label
  ///
  /// In ar, this message translates to:
  /// **'تاريخ الطلب'**
  String get placedAt;

  /// Phase 3 orders: confirmation timestamp label
  ///
  /// In ar, this message translates to:
  /// **'تاريخ التأكيد'**
  String get confirmedAt;

  /// Phase 3 orders: dispatch timestamp label
  ///
  /// In ar, this message translates to:
  /// **'تاريخ الإرسال'**
  String get dispatchedAt;

  /// Phase 3 orders: delivery timestamp label
  ///
  /// In ar, this message translates to:
  /// **'تاريخ التسليم'**
  String get deliveredAt;

  /// Phase 3 orders: cancellation timestamp label
  ///
  /// In ar, this message translates to:
  /// **'تاريخ الإلغاء'**
  String get cancelledAt;

  /// Phase 3 orders: cash total of the order
  ///
  /// In ar, this message translates to:
  /// **'الإجمالي'**
  String get orderTotal;

  /// Phase 3 orders: number of lines on a queue card
  ///
  /// In ar, this message translates to:
  /// **'عدد الأصناف'**
  String get lineCount;

  /// Phase 3 orders: delivery address snapshot label
  ///
  /// In ar, this message translates to:
  /// **'العنوان'**
  String get addressLabel;

  /// Phase 3 orders: phone snapshot label
  ///
  /// In ar, this message translates to:
  /// **'الهاتف'**
  String get phoneLabel;

  /// Phase 3 orders: the clinic's note on the order
  ///
  /// In ar, this message translates to:
  /// **'ملاحظة العميل'**
  String get clientNote;

  /// Phase 3 orders: quantity the clinic asked for
  ///
  /// In ar, this message translates to:
  /// **'المطلوب'**
  String get requestedQty;

  /// Phase 3 orders: quantity the admin approved
  ///
  /// In ar, this message translates to:
  /// **'المعتمد'**
  String get approvedQty;

  /// Phase 3 orders: quantity actually allocated from the warehouse
  ///
  /// In ar, this message translates to:
  /// **'المُجهَّز'**
  String get fulfilledQty;

  /// Phase 3 orders: billed amount of one line
  ///
  /// In ar, this message translates to:
  /// **'إجمالي الصنف'**
  String get lineTotal;

  /// Phase 3 orders: the admin approved less than requested
  ///
  /// In ar, this message translates to:
  /// **'عُدّلت الكمية عند التأكيد'**
  String get adjustedFlag;

  /// Phase 3 orders: the warehouse could not fill the approved quantity
  ///
  /// In ar, this message translates to:
  /// **'نقص في المستودع'**
  String get shortFlag;

  /// Phase 3 orders: heading over the FEFO allocation rows
  ///
  /// In ar, this message translates to:
  /// **'التشغيلات المخصّصة'**
  String get allocatedBatches;

  /// Phase 3 orders: prefix before a batch expiry date
  ///
  /// In ar, this message translates to:
  /// **'ينتهي في'**
  String get expires;

  /// Phase 3 orders: an allocation released back to its batch
  ///
  /// In ar, this message translates to:
  /// **'أُلغي الحجز'**
  String get releasedFlag;

  /// Phase 3 orders: heading of the PLACED review panel
  ///
  /// In ar, this message translates to:
  /// **'مراجعة الكميات قبل التأكيد'**
  String get reviewTitle;

  /// Phase 3 orders: stepper label, in boxes
  ///
  /// In ar, this message translates to:
  /// **'الكمية المعتمدة (علب)'**
  String get approvedBoxesLabel;

  /// Phase 3 orders: stepper minus tooltip
  ///
  /// In ar, this message translates to:
  /// **'إنقاص علبة'**
  String get decreaseQty;

  /// Phase 3 orders: stepper plus tooltip
  ///
  /// In ar, this message translates to:
  /// **'زيادة علبة'**
  String get increaseQty;

  /// Phase 3 orders: FEFO preview button
  ///
  /// In ar, this message translates to:
  /// **'معاينة التخصيص'**
  String get previewAllocation;

  /// Phase 3 orders: explains the shelf-life cutoff in the preview
  ///
  /// In ar, this message translates to:
  /// **'لا تُخصَّص تشغيلة تنتهي في هذا التاريخ أو قبله'**
  String get previewCutoff;

  /// Phase 3 orders: preview billed amount of one line
  ///
  /// In ar, this message translates to:
  /// **'الإجمالي المتوقع للصنف'**
  String get projectedLineTotal;

  /// Phase 3 orders: preview billed total
  ///
  /// In ar, this message translates to:
  /// **'الإجمالي المتوقع'**
  String get projectedTotal;

  /// Phase 3 orders: confirm button
  ///
  /// In ar, this message translates to:
  /// **'تأكيد الطلب'**
  String get confirmOrder;

  /// Phase 3 orders: snackbar after confirmation
  ///
  /// In ar, this message translates to:
  /// **'تم تأكيد الطلب'**
  String get orderConfirmed;

  /// Phase 3 orders: dispatch button
  ///
  /// In ar, this message translates to:
  /// **'إرسال للتوصيل'**
  String get dispatchOrder;

  /// Phase 3 orders: snackbar after dispatch
  ///
  /// In ar, this message translates to:
  /// **'خرج الطلب للتوصيل'**
  String get orderDispatched;

  /// Phase 3 orders: deliver button
  ///
  /// In ar, this message translates to:
  /// **'تأكيد التسليم'**
  String get deliverOrder;

  /// Phase 3 orders: deliver confirmation, stating it is final
  ///
  /// In ar, this message translates to:
  /// **'بعد تأكيد التسليم تُضاف الكميات إلى مخزون العيادة، ولا يمكن إلغاء الطلب بعدها.'**
  String get confirmDeliver;

  /// Phase 3 orders: snackbar after delivery
  ///
  /// In ar, this message translates to:
  /// **'تم تسليم الطلب'**
  String get orderDelivered;

  /// Phase 3 orders: cancel button and cancel dialog title/confirm
  ///
  /// In ar, this message translates to:
  /// **'إلغاء الطلب'**
  String get cancelOrder;

  /// Phase 3 orders: dismiss the cancel dialog without cancelling
  ///
  /// In ar, this message translates to:
  /// **'تراجع'**
  String get keepOrder;

  /// Phase 3 orders: stock effect of cancelling at PLACED
  ///
  /// In ar, this message translates to:
  /// **'لم يُحجز أي مخزون لهذا الطلب بعد، فلن يتغير المستودع.'**
  String get cancelEffectPlaced;

  /// Phase 3 orders: stock effect of cancelling at CONFIRMED
  ///
  /// In ar, this message translates to:
  /// **'ستُعاد الكميات المحجوزة إلى تشغيلاتها في المستودع.'**
  String get cancelEffectConfirmed;

  /// Phase 3 orders: asks where the goods are, at OUT_FOR_DELIVERY
  ///
  /// In ar, this message translates to:
  /// **'خرج الطلب للتوصيل. أين البضاعة الآن؟'**
  String get dispositionPrompt;

  /// Phase 3 orders: disposition RETURNED_TO_WAREHOUSE
  ///
  /// In ar, this message translates to:
  /// **'أُعيدت إلى المستودع'**
  String get dispositionReturned;

  /// Phase 3 orders: stock effect of RETURNED_TO_WAREHOUSE
  ///
  /// In ar, this message translates to:
  /// **'أعادها السائق: تُضاف الكميات إلى تشغيلاتها في المستودع.'**
  String get dispositionReturnedEffect;

  /// Phase 3 orders: disposition WRITTEN_OFF
  ///
  /// In ar, this message translates to:
  /// **'شُطبت'**
  String get dispositionWrittenOff;

  /// Phase 3 orders: stock effect of WRITTEN_OFF
  ///
  /// In ar, this message translates to:
  /// **'فُقدت أو تلفت أو بقيت لدى العيادة: لا تُضاف إلى المستودع.'**
  String get dispositionWrittenOffEffect;

  /// Phase 3 orders: optional reason field in the cancel dialog
  ///
  /// In ar, this message translates to:
  /// **'سبب الإلغاء (اختياري)'**
  String get cancelReasonLabel;

  /// Phase 3 orders: label before a cancelled order's disposition
  ///
  /// In ar, this message translates to:
  /// **'مصير البضاعة'**
  String get dispositionLabel;

  /// Phase 3 orders: disposition NOT_ALLOCATED
  ///
  /// In ar, this message translates to:
  /// **'أُلغي قبل التأكيد، ولم يُحجز مخزون'**
  String get dispositionNotAllocated;

  /// Phase 3 orders: disposition RELEASED_BEFORE_DISPATCH
  ///
  /// In ar, this message translates to:
  /// **'أُلغي قبل الإرسال، وأُعيد المخزون المحجوز'**
  String get dispositionReleasedBeforeDispatch;

  /// Phase 3 orders: a disposition this app version does not know
  ///
  /// In ar, this message translates to:
  /// **'غير معروف'**
  String get dispositionUnknown;

  /// Phase 3 orders: label before a cancelled order's reason
  ///
  /// In ar, this message translates to:
  /// **'سبب الإلغاء'**
  String get cancelReason;

  /// Phase 3 orders: snackbar after a cancellation
  ///
  /// In ar, this message translates to:
  /// **'تم إلغاء الطلب'**
  String get orderCancelled;
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
