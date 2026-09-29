import 'item.dart';

/// One line of the clinic's cart, at the LIVE price. Prices are copied onto
/// the order only when it is placed.
class CartLine {
  const CartLine({
    required this.itemId,
    required this.item,
    required this.qtyBoxes,
    required this.qtyUnits,
    required this.lineTotal,
    required this.isAvailable,
  });

  final String itemId;
  final Item item;
  final int qtyBoxes;
  final int qtyUnits;
  final String lineTotal;

  /// False once the item was deactivated. Placing the order is refused until
  /// the line is removed.
  final bool isAvailable;

  factory CartLine.fromJson(Map<String, dynamic> json) => CartLine(
    itemId: json['itemId'] as String,
    item: Item.fromJson(Map<String, dynamic>.from(json['item'] as Map)),
    qtyBoxes: (json['qtyBoxes'] as num).toInt(),
    qtyUnits: (json['qtyUnits'] as num).toInt(),
    lineTotal: json['lineTotal'] as String,
    isAvailable: json['isAvailable'] as bool,
  );
}

class Cart {
  const Cart({required this.lines, required this.lineCount, required this.totalAmount});

  final List<CartLine> lines;

  /// Every line, available or not. This is what the badge shows.
  final int lineCount;

  /// Available lines only: what placing the order now would cost.
  final String totalAmount;

  bool get isEmpty => lines.isEmpty;

  factory Cart.fromJson(Map<String, dynamic> json) => Cart(
    lines: (json['lines'] as List<dynamic>)
        .map((e) => CartLine.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
    lineCount: (json['lineCount'] as num).toInt(),
    totalAmount: json['totalAmount'] as String,
  );
}
