/// Why a notification was sent (spec §6). The apps show the server's Arabic
/// as-is; the type only decides the icon and where a tap goes.
enum NotificationType {
  accountApproved('ACCOUNT_APPROVED'),
  accountRejected('ACCOUNT_REJECTED'),
  orderPlaced('ORDER_PLACED'),
  orderConfirmed('ORDER_CONFIRMED'),
  orderOutForDelivery('ORDER_OUT_FOR_DELIVERY'),
  orderDelivered('ORDER_DELIVERED'),
  orderCancelled('ORDER_CANCELLED'),
  lowStock('LOW_STOCK'),
  outOfStock('OUT_OF_STOCK'),
  clientOutOfStock('CLIENT_OUT_OF_STOCK'),
  expiryWarning('EXPIRY_WARNING'),
  adminBroadcast('ADMIN_BROADCAST'),
  unknown('UNKNOWN');

  const NotificationType(this.wire);

  final String wire;

  static NotificationType fromWire(String? value) => values.firstWhere(
    (t) => t.wire == value && t != unknown,
    orElse: () => unknown,
  );
}

/// One notification. Named `AppNotification` because Flutter already has a
/// `Notification` class.
class AppNotification {
  const AppNotification({
    required this.id,
    required this.type,
    required this.titleAr,
    required this.bodyAr,
    required this.createdAt,
    this.orderId,
    this.itemId,
    this.clientId,
    this.readAt,
  });

  final String id;
  final NotificationType type;
  final String titleAr;
  final String bodyAr;

  /// Deep-link targets from the payload; at most the relevant ones are set.
  final String? orderId;
  final String? itemId;
  final String? clientId;
  final DateTime? readAt;
  final DateTime createdAt;

  bool get isRead => readAt != null;

  factory AppNotification.fromJson(Map<String, dynamic> json) {
    final payload = json['payload'] == null
        ? const <String, dynamic>{}
        : Map<String, dynamic>.from(json['payload'] as Map);
    return AppNotification(
      id: json['id'] as String,
      type: NotificationType.fromWire(json['type'] as String?),
      titleAr: json['titleAr'] as String,
      bodyAr: json['bodyAr'] as String,
      orderId: payload['orderId'] as String?,
      itemId: payload['itemId'] as String?,
      clientId: payload['clientId'] as String?,
      readAt: json['readAt'] == null
          ? null
          : DateTime.parse(json['readAt'] as String),
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }
}

class NotificationPage {
  const NotificationPage({
    required this.items,
    required this.unreadCount,
    this.nextCursor,
  });

  final List<AppNotification> items;
  final String? nextCursor;

  /// All unread, not just on this page: what the bell shows.
  final int unreadCount;

  bool get hasMore => nextCursor != null;

  factory NotificationPage.fromJson(Map<String, dynamic> json) =>
      NotificationPage(
        items: (json['items'] as List<dynamic>)
            .map(
              (e) =>
                  AppNotification.fromJson(Map<String, dynamic>.from(e as Map)),
            )
            .toList(),
        nextCursor: json['nextCursor'] as String?,
        unreadCount: (json['unreadCount'] as num).toInt(),
      );
}

enum JobRunStatus {
  running('RUNNING'),
  succeeded('SUCCEEDED'),
  failed('FAILED'),
  unknown('UNKNOWN');

  const JobRunStatus(this.wire);

  final String wire;

  static JobRunStatus fromWire(String? value) => values.firstWhere(
    (s) => s.wire == value && s != unknown,
    orElse: () => unknown,
  );
}

/// One nightly job's run (spec §8's run log).
class JobRun {
  const JobRun({
    required this.id,
    required this.job,
    required this.status,
    required this.startedAt,
    this.finishedAt,
    this.summary,
    this.error,
  });

  final String id;
  final String job;
  final JobRunStatus status;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final Map<String, dynamic>? summary;
  final String? error;

  factory JobRun.fromJson(Map<String, dynamic> json) => JobRun(
    id: json['id'] as String,
    job: json['job'] as String,
    status: JobRunStatus.fromWire(json['status'] as String?),
    startedAt: DateTime.parse(json['startedAt'] as String),
    finishedAt: json['finishedAt'] == null
        ? null
        : DateTime.parse(json['finishedAt'] as String),
    summary: json['summary'] == null
        ? null
        : Map<String, dynamic>.from(json['summary'] as Map),
    error: json['error'] as String?,
  );
}
