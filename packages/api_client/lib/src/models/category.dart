/// A catalog category. Up to three levels deep (requirement 1).
class Category {
  const Category({
    required this.id,
    required this.nameAr,
    required this.level,
    this.nameEn,
    this.parentId,
    this.sortOrder = 0,
    this.imageUrl,
    this.isActive = true,
    this.children = const [],
  });

  final String id;
  final String nameAr;
  final String? nameEn;
  final String? parentId;
  final int level;
  final int sortOrder;
  final String? imageUrl;
  final bool isActive;
  final List<Category> children;

  /// Arabic first — the app is Arabic-only; English is a fallback for items
  /// a supplier only named in English.
  String get displayName => nameAr.isNotEmpty ? nameAr : (nameEn ?? '');

  bool get hasChildren => children.isNotEmpty;

  /// A level-3 category can hold no further children, so the UI must not
  /// offer an "add sub-category" action the server would reject.
  bool get canHaveChildren => level < 3;

  factory Category.fromJson(Map<String, dynamic> json) => Category(
    id: json['id'] as String,
    nameAr: (json['nameAr'] as String?) ?? '',
    nameEn: json['nameEn'] as String?,
    parentId: json['parentId'] as String?,
    level: (json['level'] as num).toInt(),
    sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 0,
    imageUrl: json['imageUrl'] as String?,
    isActive: (json['isActive'] as bool?) ?? true,
    children: ((json['children'] as List<dynamic>?) ?? const [])
        .map((e) => Category.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
  );
}
