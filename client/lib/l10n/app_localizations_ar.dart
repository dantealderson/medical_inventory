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

  @override
  String get search => 'بحث';

  @override
  String get searchHint => 'ابحث عن صنف...';

  @override
  String get noResults => 'لا توجد نتائج';

  @override
  String get categories => 'الأقسام';

  @override
  String get items => 'الأصناف';

  @override
  String get noItemsInCategory => 'لا توجد أصناف في هذا القسم';

  @override
  String get pricePerBox => 'سعر العلبة';

  @override
  String get unitsPerBox => 'عدد الوحدات في العلبة';

  @override
  String get boxesShort => 'علبة';

  @override
  String get home => 'الرئيسية';

  @override
  String get back => 'رجوع';

  @override
  String get noCategoriesYet => 'لم تتم إضافة أقسام بعد';

  @override
  String get searchFailed => 'تعذر البحث، حاول مرة أخرى';

  @override
  String get matchingCategories => 'أقسام مطابقة';

  @override
  String get matchingItems => 'أصناف مطابقة';

  @override
  String get cart => 'السلة';

  @override
  String addToCart(String name) {
    return 'أضف $name إلى السلة';
  }

  @override
  String addedToCart(String name) {
    return 'تمت إضافة $name إلى السلة';
  }

  @override
  String get cartEmpty => 'السلة فارغة';

  @override
  String get itemUnavailable =>
      'هذا الصنف لم يعد متوفراً، يرجى إزالته من السلة';

  @override
  String get increaseQty => 'زيادة الكمية';

  @override
  String get decreaseQty => 'إنقاص الكمية';

  @override
  String get cartTotal => 'المجموع';

  @override
  String get myOrders => 'طلباتي';

  @override
  String get placeOrder => 'إرسال الطلب';

  @override
  String get orderNote => 'ملاحظة للمورد (اختياري)';

  @override
  String get noOrders => 'لا توجد طلبات بعد';

  @override
  String get loadMore => 'عرض المزيد';

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
  String get orderDetails => 'تفاصيل الطلب';

  @override
  String get orderTotal => 'المبلغ المستحق عند الاستلام';

  @override
  String orderLineCount(int count) {
    return 'عدد الأصناف: $count';
  }

  @override
  String get timelinePlaced => 'تم إرسال الطلب';

  @override
  String get timelineConfirmed => 'أكّد المورد الطلب';

  @override
  String get timelineOutForDelivery => 'خرج الطلب للتوصيل';

  @override
  String get timelineDelivered => 'تم تسليم الطلب';

  @override
  String get timelineCancelled => 'أُلغي الطلب';

  @override
  String requestedQty(String qty) {
    return 'المطلوب: $qty';
  }

  @override
  String approvedQty(String qty) {
    return 'الموافق عليه: $qty';
  }

  @override
  String fulfilledQty(String qty) {
    return 'المجهَّز: $qty';
  }

  @override
  String get adjustedBySupplierNote => 'عدّل المورد الكمية التي طلبتها';

  @override
  String shortStockNote(String qty) {
    return 'نقص في المخزون: لم يتوفر $qty';
  }

  @override
  String get cancelOrder => 'إلغاء الطلب';

  @override
  String get cancelOrderQuestion => 'هل تريد إلغاء هذا الطلب؟';

  @override
  String get keepOrder => 'لا، أبقِ الطلب';

  @override
  String get confirmCancelOrder => 'نعم، ألغِ الطلب';

  @override
  String get orderCancelled => 'تم إلغاء الطلب';

  @override
  String get dispositionNotAllocated => 'أُلغي الطلب قبل تأكيده.';

  @override
  String get dispositionReleasedBeforeDispatch =>
      'أُلغي الطلب بعد تأكيده وقبل خروجه للتوصيل.';

  @override
  String get dispositionReturnedToWarehouse =>
      'أُلغي الطلب وأُعيدت البضاعة إلى المستودع.';

  @override
  String get dispositionWrittenOff => 'أُلغي الطلب بعد خروجه للتوصيل.';

  @override
  String get dispositionUnknown => 'أُلغي الطلب.';

  @override
  String get nextExpiry => 'صلاحية الكمية التي ستصلك';

  @override
  String get currentlyUnavailable => 'غير متوفر حالياً';

  @override
  String get myInventory => 'مخزوني';

  @override
  String get inventoryEmpty =>
      'لا توجد أصناف في مخزونك بعد. ستظهر هنا بعد استلام أول طلب.';

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
  String get sourceManual => 'معدل الاستهلاك حدده المورد';

  @override
  String get sourceMeasured => 'تقدير من الجرد';

  @override
  String get sourcePurchase => 'تقدير من مشترياتك';

  @override
  String batchExpiresOn(String batch, String date) {
    return 'الدفعة $batch تنتهي صلاحيتها في $date';
  }

  @override
  String batchExpired(String batch, String date) {
    return 'الدفعة $batch منتهية الصلاحية منذ $date';
  }

  @override
  String batchLabel(String batch) {
    return 'الدفعة $batch';
  }

  @override
  String get lowStockTitle => 'أصناف تحتاج إلى طلب';

  @override
  String get seeAll => 'عرض الكل';

  @override
  String get movementHistory => 'سجل الحركة';

  @override
  String get reasonDeliveryIn => 'استلام طلب';

  @override
  String get reasonAutoDecrement => 'استهلاك تقديري';

  @override
  String get reasonStockCount => 'تصحيح بالجرد';

  @override
  String get reasonManualAdjust => 'تعديل من المورد';

  @override
  String get reasonOther => 'حركة';

  @override
  String get stockCount => 'جرد المخزون';

  @override
  String get countBoxes => 'علب';

  @override
  String countLooseUnits(String unit) {
    return '$unit مفردة';
  }

  @override
  String get countHint =>
      'اكتب ما تجده فعلاً على الرف. اترك الصنف فارغاً إذا لم تعدّه.';

  @override
  String get saveCount => 'حفظ الجرد';

  @override
  String confirmCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'سيتم تحديث $count صنف حسب الجرد. هل تريد المتابعة؟',
      many: 'سيتم تحديث $count صنفاً حسب الجرد. هل تريد المتابعة؟',
      few: 'سيتم تحديث $count أصناف حسب الجرد. هل تريد المتابعة؟',
      two: 'سيتم تحديث صنفين حسب الجرد. هل تريد المتابعة؟',
      one: 'سيتم تحديث صنف واحد حسب الجرد. هل تريد المتابعة؟',
    );
    return '$_temp0';
  }

  @override
  String get confirm => 'متابعة';

  @override
  String get cancel => 'إلغاء';

  @override
  String get countSaved => 'تم حفظ الجرد';

  @override
  String countWasNow(String before, String after) {
    return 'كان $before، الآن $after';
  }

  @override
  String countLess(String qty) {
    return 'نقص $qty';
  }

  @override
  String countMore(String qty) {
    return 'زيادة $qty';
  }

  @override
  String get countSame => 'بدون تغيير';

  @override
  String get backToInventory => 'العودة إلى مخزوني';

  @override
  String get notifications => 'الإشعارات';

  @override
  String get noNotifications => 'لا توجد إشعارات';

  @override
  String get markAllRead => 'تحديد الكل كمقروء';

  @override
  String get unreadLabel => 'جديد';
}
