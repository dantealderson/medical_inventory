/// A catalog item, priced and ordered by the box.
class Item {
  const Item({
    required this.id,
    required this.categoryId,
    required this.unitsPerBox,
    required this.unitLabelAr,
    required this.pricePerBox,
    this.nameAr,
    this.nameEn,
    this.description,
    this.unitLabelEn,
    this.imageUrl,
    this.minQtyUnits,
    this.minQtyBoxes,
    this.isActive = true,
  });

  final String id;
  final String? nameAr;
  final String? nameEn;
  final String? description;
  final String categoryId;

  /// Base units in one box, e.g. 100 syringes.
  final int unitsPerBox;
  final String unitLabelAr;
  final String? unitLabelEn;

  /// A String, never a double. Binary floats cannot represent money exactly —
  /// 12.10 becomes 12.099999999999999 and eventually prints wrong on an
  /// invoice. Formatting is a display concern; the value stays exact.
  final String pricePerBox;

  final String? imageUrl;
  final int? minQtyUnits;
  final int? minQtyBoxes;
  final bool isActive;

  String get displayName => (nameAr?.isNotEmpty ?? false) ? nameAr! : (nameEn ?? '');

  factory Item.fromJson(Map<String, dynamic> json) => Item(
    id: json['id'] as String,
    nameAr: json['nameAr'] as String?,
    nameEn: json['nameEn'] as String?,
    description: json['description'] as String?,
    categoryId: json['categoryId'] as String,
    unitsPerBox: (json['unitsPerBox'] as num).toInt(),
    unitLabelAr: json['unitLabelAr'] as String,
    unitLabelEn: json['unitLabelEn'] as String?,
    pricePerBox: json['pricePerBox'].toString(),
    imageUrl: json['imageUrl'] as String?,
    minQtyUnits: (json['minQtyUnits'] as num?)?.toInt(),
    minQtyBoxes: (json['minQtyBoxes'] as num?)?.toInt(),
    isActive: (json['isActive'] as bool?) ?? true,
  );
}

/// One cursor-paginated page of items.
class ItemPage {
  const ItemPage({required this.items, this.nextCursor});

  final List<Item> items;
  final String? nextCursor;

  bool get hasMore => nextCursor != null;

  factory ItemPage.fromJson(Map<String, dynamic> json) => ItemPage(
    items: (json['items'] as List<dynamic>)
        .map((e) => Item.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
    nextCursor: json['nextCursor'] as String?,
  );
}
