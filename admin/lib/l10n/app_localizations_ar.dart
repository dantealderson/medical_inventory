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
  String get serverUnreachable => 'تعذر الاتصال بالخادم، تحقق من الإنترنت';

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

  @override
  String get orders => 'الطلبات';

  @override
  String get orderDetails => 'تفاصيل الطلب';

  @override
  String get noOrders => 'لا توجد طلبات بهذه الحالة';

  @override
  String get loadMore => 'عرض المزيد';

  @override
  String get allStatuses => 'الكل';

  @override
  String get orderStatusPlaced => 'بانتظار التأكيد';

  @override
  String get orderStatusConfirmed => 'مؤكد';

  @override
  String get orderStatusOutForDelivery => 'قيد التوصيل';

  @override
  String get orderStatusDelivered => 'تم التسليم';

  @override
  String get orderStatusCancelled => 'ملغى';

  @override
  String get orderStatusUnknown => 'حالة غير معروفة';

  @override
  String get placedAt => 'تاريخ الطلب';

  @override
  String get confirmedAt => 'تاريخ التأكيد';

  @override
  String get dispatchedAt => 'تاريخ الإرسال';

  @override
  String get deliveredAt => 'تاريخ التسليم';

  @override
  String get cancelledAt => 'تاريخ الإلغاء';

  @override
  String get orderTotal => 'الإجمالي';

  @override
  String get lineCount => 'عدد الأصناف';

  @override
  String get addressLabel => 'العنوان';

  @override
  String get phoneLabel => 'الهاتف';

  @override
  String get clientNote => 'ملاحظة العميل';

  @override
  String get requestedQty => 'المطلوب';

  @override
  String get approvedQty => 'المعتمد';

  @override
  String get fulfilledQty => 'المُجهَّز';

  @override
  String get lineTotal => 'إجمالي الصنف';

  @override
  String get adjustedFlag => 'عُدّلت الكمية عند التأكيد';

  @override
  String get shortFlag => 'نقص في المستودع';

  @override
  String get allocatedBatches => 'التشغيلات المخصّصة';

  @override
  String get expires => 'ينتهي في';

  @override
  String get releasedFlag => 'أُلغي الحجز';

  @override
  String get reviewTitle => 'مراجعة الكميات قبل التأكيد';

  @override
  String get approvedBoxesLabel => 'الكمية المعتمدة (علب)';

  @override
  String get decreaseQty => 'إنقاص علبة';

  @override
  String get increaseQty => 'زيادة علبة';

  @override
  String get previewAllocation => 'معاينة التخصيص';

  @override
  String get previewCutoff => 'لا تُخصَّص تشغيلة تنتهي في هذا التاريخ أو قبله';

  @override
  String get projectedLineTotal => 'الإجمالي المتوقع للصنف';

  @override
  String get projectedTotal => 'الإجمالي المتوقع';

  @override
  String get confirmOrder => 'تأكيد الطلب';

  @override
  String get orderConfirmed => 'تم تأكيد الطلب';

  @override
  String get orderConfirmedShort => 'تم تأكيد الطلب مع نقص في بعض الأصناف';

  @override
  String get dispatchOrder => 'إرسال للتوصيل';

  @override
  String get orderDispatched => 'خرج الطلب للتوصيل';

  @override
  String get deliverOrder => 'تأكيد التسليم';

  @override
  String get confirmDeliver =>
      'بعد تأكيد التسليم تُضاف الكميات إلى مخزون العيادة، ولا يمكن إلغاء الطلب بعدها.';

  @override
  String get orderDelivered => 'تم تسليم الطلب';

  @override
  String get cancelOrder => 'إلغاء الطلب';

  @override
  String get keepOrder => 'تراجع';

  @override
  String get cancelEffectPlaced =>
      'لم يُحجز أي مخزون لهذا الطلب بعد، فلن يتغير المستودع.';

  @override
  String get cancelEffectConfirmed =>
      'ستُعاد الكميات المحجوزة إلى تشغيلاتها في المستودع.';

  @override
  String get dispositionPrompt => 'خرج الطلب للتوصيل. أين البضاعة الآن؟';

  @override
  String get dispositionReturned => 'أُعيدت إلى المستودع';

  @override
  String get dispositionReturnedEffect =>
      'أعادها السائق: تُضاف الكميات إلى تشغيلاتها في المستودع.';

  @override
  String get dispositionWrittenOff => 'شُطبت';

  @override
  String get dispositionWrittenOffEffect =>
      'فُقدت أو تلفت أو بقيت لدى العيادة: لا تُضاف إلى المستودع.';

  @override
  String get cancelReasonLabel => 'سبب الإلغاء (اختياري)';

  @override
  String get dispositionLabel => 'مصير البضاعة';

  @override
  String get dispositionNotAllocated => 'أُلغي قبل التأكيد، ولم يُحجز مخزون';

  @override
  String get dispositionReleasedBeforeDispatch =>
      'أُلغي قبل الإرسال، وأُعيد المخزون المحجوز';

  @override
  String get dispositionUnknown => 'غير معروف';

  @override
  String get cancelReason => 'سبب الإلغاء';

  @override
  String get orderCancelled => 'تم إلغاء الطلب';

  @override
  String get hotDeals => 'العروض';

  @override
  String get hotDealsRebuildHint =>
      'تُحسب العروض «الأكثر طلباً» و«الجديدة» عند إعادة البناء، أما المثبّتة فتبقى كما هي.';

  @override
  String get rebuildHotDeals => 'إعادة بناء القائمة';

  @override
  String get hotDealsRebuilt => 'تمت إعادة بناء العروض';

  @override
  String get hotDealsLastRebuilt => 'آخر إعادة بناء';

  @override
  String get hotDealsNeverRebuilt => 'لم تُبنَ القائمة بعد';

  @override
  String get noHotDeals => 'لا توجد عروض بعد';

  @override
  String get hotDealKindManual => 'مثبّت';

  @override
  String get hotDealKindFrequent => 'الأكثر طلباً';

  @override
  String get hotDealKindNew => 'جديد';

  @override
  String get hotDealKindUnknown => 'غير معروف';

  @override
  String get hotDealHiddenInactive => 'مخفي عن العملاء: الصنف غير مفعّل';

  @override
  String get pinItem => 'تثبيت صنف';

  @override
  String get pinItemTitle => 'اختر صنفاً لتثبيته في العروض';

  @override
  String get unpin => 'إلغاء التثبيت';

  @override
  String get itemPinned => 'تم تثبيت الصنف';

  @override
  String get noItemsToPin => 'لا توجد أصناف مفعّلة غير مثبّتة';

  @override
  String get clientInventory => 'مخزون العميل';

  @override
  String get clientInventoryEmpty => 'لا توجد أصناف في مخزون هذا العميل بعد';

  @override
  String get stockRed => 'ناقص';

  @override
  String get stockOut => 'نفد';

  @override
  String get stockYellow => 'قليل';

  @override
  String get stockGreen => 'جيد';

  @override
  String get stockUnknown => 'غير محدد';

  @override
  String daysOfCover(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'يكفي حوالي $days يوم',
      many: 'يكفي حوالي $days يوماً',
      few: 'يكفي حوالي $days أيام',
      two: 'يكفي يومين',
      one: 'يكفي يوماً واحداً',
      zero: 'يكفي أقل من يوم',
    );
    return '$_temp0';
  }

  @override
  String get noEstimate => 'لا توجد بيانات كافية';

  @override
  String get sourceManual => 'معدل محدد من الإدارة';

  @override
  String get sourceMeasured => 'مقاس من الجرد';

  @override
  String get sourcePurchase => 'تقدير من المشتريات';

  @override
  String get autoDecrement => 'الخصم التلقائي';

  @override
  String get usageRateField => 'معدل الاستهلاك (وحدة/يوم)';

  @override
  String get minBoxesField => 'الحد الأدنى (علب)';

  @override
  String get clearValue => 'مسح';

  @override
  String get invalidRate => 'أدخل رقماً بأربع منازل عشرية على الأكثر';

  @override
  String get changesSaved => 'تم حفظ التغييرات';

  @override
  String get notifications => 'الإشعارات';

  @override
  String get noNotifications => 'لا توجد إشعارات';

  @override
  String get markAllRead => 'تحديد الكل كمقروء';

  @override
  String get unreadLabel => 'جديد';

  @override
  String get newMessage => 'رسالة جديدة';

  @override
  String get messageTitle => 'العنوان';

  @override
  String get messageBody => 'نص الرسالة';

  @override
  String get audienceAll => 'جميع العملاء';

  @override
  String get audienceSelected => 'عملاء محددون';

  @override
  String get send => 'إرسال';

  @override
  String get chooseAtLeastOneClinic => 'اختر عميلاً واحداً على الأقل';

  @override
  String sentTo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'تم الإرسال إلى $count عميل',
      many: 'تم الإرسال إلى $count عميلاً',
      few: 'تم الإرسال إلى $count عملاء',
      two: 'تم الإرسال إلى عميلين',
      one: 'تم الإرسال إلى عميل واحد',
      zero: 'لم يتم الإرسال إلى أي عميل',
    );
    return '$_temp0';
  }

  @override
  String get trackingStoppedByClinic => 'أوقف العميل متابعته';

  @override
  String get dashboard => 'الرئيسية';

  @override
  String get pendingApprovalsCard => 'حسابات بانتظار الموافقة';

  @override
  String get ordersAwaitingCard => 'طلبات بانتظار التأكيد';

  @override
  String get outOfStockClinicsTitle => 'عملاء نفد مخزونهم';

  @override
  String clinicOutLine(String clinic, String items) {
    return '$clinic: $items';
  }

  @override
  String get warehouseAlertsTitle => 'المستودع: أصناف ناقصة أو نافدة';

  @override
  String warehouseOut(String item) {
    return '$item — نفد';
  }

  @override
  String warehouseLow(String item, String qty) {
    return '$item — ناقص: $qty';
  }

  @override
  String get expiringBatchesTitle => 'دفعات قاربت على الانتهاء';

  @override
  String batchExpiresLine(String batch, String item, String date) {
    return '$batch — $item: تنتهي في $date';
  }

  @override
  String batchExpiredLine(String batch, String item, String date) {
    return '$batch — $item: منتهية منذ $date';
  }

  @override
  String get nothingToShow => 'لا يوجد';

  @override
  String get nightlyTitle => 'التحديث الليلي';

  @override
  String lastRunAt(String when) {
    return 'آخر تشغيل: $when';
  }

  @override
  String get runSucceeded => 'تم بنجاح';

  @override
  String runFailed(String jobs) {
    return 'فشل: $jobs';
  }

  @override
  String get runStillGoing => 'قيد التشغيل';

  @override
  String get neverRun => 'لم يعمل بعد';

  @override
  String get runNow => 'تشغيل الآن';

  @override
  String get close => 'إغلاق';

  @override
  String get settings => 'الإعدادات';

  @override
  String get auditLog => 'سجل التدقيق';

  @override
  String get settingsSaved => 'تم حفظ الإعدادات';

  @override
  String get valueRejected => 'القيمة غير مقبولة';

  @override
  String get settingsStock => 'المخزون';

  @override
  String get settingsEstimation => 'التقدير';

  @override
  String get settingsAlerts => 'التنبيهات';

  @override
  String get settingsExpiry => 'الصلاحية';

  @override
  String get settingsHotDeals => 'العروض';

  @override
  String get settingsGeneral => 'عام';

  @override
  String get timezoneLabel => 'المنطقة الزمنية';

  @override
  String get settingRedDays => 'أحمر إذا كان المخزون يكفي أقل من (يوم)';

  @override
  String get settingYellowDays => 'أصفر إذا كان المخزون يكفي أقل من (يوم)';

  @override
  String get settingPurchaseWindow => 'فترة حساب الاستهلاك من المشتريات (يوم)';

  @override
  String get settingMinPurchase => 'أقل مدة مشتريات قبل التقدير (يوم)';

  @override
  String get settingMinMeasure => 'أقل مدة بين عمليتي جرد للقياس (يوم)';

  @override
  String get settingMeasureWindow => 'فترة الجرد المعتمدة للقياس (يوم)';

  @override
  String get settingMaxCatchUp => 'أقصى أيام خصم متأخر في مرة واحدة';

  @override
  String get settingRepeatAlerts => 'تكرار تنبيه الصنف نفسه بعد (يوم)';

  @override
  String get settingWarnAhead => 'التنبيه قبل انتهاء الصلاحية بـ (يوم)';

  @override
  String get settingMinShelfLife => 'أقل صلاحية متبقية عند التسليم (يوم)';

  @override
  String get settingRotation => 'مدة عرض كل عرض (ثانية)';

  @override
  String get settingFrequentWindow => 'فترة حساب الأصناف الأكثر طلباً (يوم)';

  @override
  String get settingNewItemDays => 'يعتبر الصنف جديداً لمدة (يوم)';

  @override
  String get settingMaxEntries => 'أقصى عدد للعروض';

  @override
  String get search => 'بحث';

  @override
  String get allEntities => 'الكل';

  @override
  String get entityFilter => 'النوع';

  @override
  String get fromDate => 'من (مثال 2027-01-31)';

  @override
  String get toDate => 'إلى (مثال 2027-01-31)';

  @override
  String get invalidDate => 'اكتب التاريخ بالشكل 2027-01-31';

  @override
  String get beforeLabel => 'قبل';

  @override
  String get afterLabel => 'بعد';

  @override
  String get noAuditEntries => 'لا توجد سجلات';

  @override
  String get clientOrders => 'طلبات العميل';

  @override
  String get entityUser => 'الحسابات';

  @override
  String get entityItem => 'الأصناف';

  @override
  String get entityCategory => 'الأقسام';

  @override
  String get entityOrder => 'الطلبات';

  @override
  String get entityClientInventory => 'مخزون العملاء';

  @override
  String get entitySettings => 'الإعدادات';

  @override
  String get entityBatch => 'الدفعات';

  @override
  String get auditClientApproved => 'الموافقة على حساب';

  @override
  String get auditClientRejected => 'رفض حساب';

  @override
  String get auditClientSuspended => 'إيقاف حساب';

  @override
  String get auditClientReactivated => 'إعادة تفعيل حساب';

  @override
  String get auditPasswordReset => 'إعادة تعيين كلمة المرور';

  @override
  String get auditCategoryCreated => 'إضافة قسم';

  @override
  String get auditCategoryUpdated => 'تعديل قسم';

  @override
  String get auditCategoryDeleted => 'حذف قسم';

  @override
  String get auditItemCreated => 'إضافة صنف';

  @override
  String get auditItemUpdated => 'تعديل صنف';

  @override
  String get auditItemDeactivated => 'إيقاف صنف';

  @override
  String get auditBatchReceived => 'استلام دفعة';

  @override
  String get auditOrderConfirmed => 'تأكيد طلب';

  @override
  String get auditOrderCancelled => 'إلغاء طلب';

  @override
  String get auditHotDealPinned => 'تثبيت عرض';

  @override
  String get auditHotDealUnpinned => 'إلغاء تثبيت عرض';

  @override
  String get auditAutoDecrementEnabled => 'تشغيل الخصم التلقائي';

  @override
  String get auditAutoDecrementDisabled => 'إيقاف الخصم التلقائي';

  @override
  String get auditRateSet => 'تحديد معدل الاستهلاك';

  @override
  String get auditRateCleared => 'مسح معدل الاستهلاك';

  @override
  String get auditMinChanged => 'تغيير الحد الأدنى';

  @override
  String get auditSettingsChanged => 'تغيير الإعدادات';
}
