import 'item.dart';

/// Why an item is on the home carousel (§7.7).
enum HotDealKind {
  frequent('FREQUENT'),

  /// Wire value `NEW`. `new` is a Dart keyword, so the member is `newItem`.
  newItem('NEW'),
  manual('MANUAL'),
  unknown('UNKNOWN');

  const HotDealKind(this.wire);

  final String wire;

  static HotDealKind fromWire(String? value) => switch (value) {
    'FREQUENT' => frequent,
    'NEW' => newItem,
    'MANUAL' => manual,
    _ => unknown,
  };
}

class HotDealEntry {
  const HotDealEntry({
    required this.itemId,
    required this.kind,
    required this.sortOrder,
    required this.item,
  });

  final String itemId;
  final HotDealKind kind;
  final int sortOrder;
  final Item item;

  factory HotDealEntry.fromJson(Map<String, dynamic> json) => HotDealEntry(
    itemId: json['itemId'] as String,
    kind: HotDealKind.fromWire(json['kind'] as String?),
    sortOrder: (json['sortOrder'] as num).toInt(),
    item: Item.fromJson(Map<String, dynamic>.from(json['item'] as Map)),
  );
}

List<HotDealEntry> _entries(Object? value) => (value as List<dynamic>)
    .map((e) => HotDealEntry.fromJson(Map<String, dynamic>.from(e as Map)))
    .toList();

/// What the clinic home shows: one entry per item, active items only, capped.
class HotDeals {
  const HotDeals({required this.rotationSeconds, required this.entries});

  final int rotationSeconds;
  final List<HotDealEntry> entries;

  factory HotDeals.fromJson(Map<String, dynamic> json) => HotDeals(
    rotationSeconds: (json['rotationSeconds'] as num).toInt(),
    entries: _entries(json['entries']),
  );
}

/// Every row, including an item listed under several kinds and inactive items.
class AdminHotDeals {
  const AdminHotDeals({required this.entries, this.computedAt});

  final List<HotDealEntry> entries;

  /// When FREQUENT and NEW were last rebuilt. Null before the first rebuild.
  final DateTime? computedAt;

  factory AdminHotDeals.fromJson(Map<String, dynamic> json) => AdminHotDeals(
    entries: _entries(json['entries']),
    computedAt: json['computedAt'] == null ? null : DateTime.parse(json['computedAt'] as String),
  );
}
