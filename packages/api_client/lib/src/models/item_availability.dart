/// What a clinic would receive if an order were confirmed now (§12.2). A date
/// and a yes/no, never a quantity: warehouse stock is not client-visible.
class ItemAvailability {
  const ItemAvailability({required this.itemId, required this.inStock, this.nextExpiryDate});

  final String itemId;
  final bool inStock;

  /// The calendar date on the batch FEFO would ship first. Null when nothing
  /// is eligible.
  final DateTime? nextExpiryDate;

  factory ItemAvailability.fromJson(Map<String, dynamic> json) => ItemAvailability(
    itemId: json['itemId'] as String,
    inStock: json['inStock'] as bool,
    nextExpiryDate: json['nextExpiryDate'] == null
        ? null
        : DateTime.parse(json['nextExpiryDate'] as String),
  );
}
