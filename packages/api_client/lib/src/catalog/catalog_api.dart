import 'package:dio/dio.dart';

import '../api_client_base.dart';
import '../api_exception.dart';
import '../models/category.dart';
import '../models/item.dart';
import '../models/item_availability.dart';
import '../models/warehouse_batch.dart';

/// Shared request/unwrap plumbing for the catalog APIs.
///
/// Every failure surfaces as [ApiException] so the apps switch on `code` and
/// display `messageAr`, and never touch a Dio type.
abstract class _CatalogApiBase {
  _CatalogApiBase(ApiClient client) : dio = client.dio;

  final Dio dio;

  Map<String, dynamic> asMap(Object? data) => Map<String, dynamic>.from(data as Map);

  Future<T> call<T>(
    Future<Response<dynamic>> Function() send,
    T Function(Object? data) parse,
  ) async {
    try {
      return parse((await send()).data);
    } on DioException catch (e) {
      final wrapped = e.error;
      throw wrapped is ApiException ? wrapped : ApiException.fromDioError(e);
    }
  }
}

/// A picture upload: the server reads multipart field `file`.
FormData _pictureForm(List<int> bytes, String filename) =>
    FormData.fromMap({'file': MultipartFile.fromBytes(bytes, filename: filename)});

class CategoriesApi extends _CatalogApiBase {
  CategoriesApi(super.client);

  /// The whole tree, already nested by the server.
  Future<List<Category>> tree() => call(
    () => dio.get<dynamic>('/categories'),
    (data) => (data as List<dynamic>)
        .map((e) => Category.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
  );

  Future<Category> create({
    required String nameAr,
    String? nameEn,
    String? parentId,
    int? sortOrder,
    String? imageUrl,
  }) {
    // `level` is deliberately not sent: the server derives it from the parent,
    // and forbidNonWhitelisted would reject it anyway. That is what stops a
    // caller declaring its own depth and skipping the three-level check.
    final body = <String, dynamic>{'nameAr': nameAr};
    if (nameEn != null) body['nameEn'] = nameEn;
    if (parentId != null) body['parentId'] = parentId;
    if (sortOrder != null) body['sortOrder'] = sortOrder;
    if (imageUrl != null) body['imageUrl'] = imageUrl;

    return call(
      () => dio.post<dynamic>('/admin/categories', data: body),
      (data) => Category.fromJson(asMap(data)),
    );
  }

  Future<Category> update(String id, Map<String, dynamic> changes) => call(
    () => dio.patch<dynamic>('/admin/categories/$id', data: changes),
    (data) => Category.fromJson(asMap(data)),
  );

  Future<void> delete(String id) =>
      call(() => dio.delete<dynamic>('/admin/categories/$id'), (_) {});

  /// Uploads a picture and attaches it, replacing any before (admin).
  Future<Category> setImage(String id, List<int> bytes, String filename) => call(
    () => dio.put<dynamic>('/admin/categories/$id/image', data: _pictureForm(bytes, filename)),
    (data) => Category.fromJson(asMap(data)),
  );

  Future<Category> removeImage(String id) => call(
    () => dio.delete<dynamic>('/admin/categories/$id/image'),
    (data) => Category.fromJson(asMap(data)),
  );
}

class ItemsApi extends _CatalogApiBase {
  ItemsApi(super.client);

  /// [includeInactive] is honoured for admins only; clinics always get
  /// active items.
  Future<ItemPage> list({String? categoryId, String? cursor, int? limit, bool includeInactive = false}) => call(
    () => dio.get<dynamic>(
      '/items',
      queryParameters: {
        if (categoryId != null) 'categoryId': categoryId,
        if (cursor != null) 'cursor': cursor,
        if (limit != null) 'limit': limit,
        if (includeInactive) 'includeInactive': 'true',
      },
    ),
    (data) => ItemPage.fromJson(asMap(data)),
  );

  /// Every page of [list], for screens with no «load more».
  Future<List<Item>> listAll({String? categoryId, bool includeInactive = false}) async {
    final items = <Item>[];
    String? cursor;
    do {
      // 100 is the server's maximum page size.
      final page = await list(categoryId: categoryId, cursor: cursor, limit: 100, includeInactive: includeInactive);
      items.addAll(page.items);
      cursor = page.nextCursor;
    } while (cursor != null);
    return items;
  }

  Future<Item> byId(String id) =>
      call(() => dio.get<dynamic>('/items/$id'), (data) => Item.fromJson(asMap(data)));

  /// The expiry of the stock a clinic would receive if an order were
  /// confirmed now: the same rule the warehouse uses to allocate.
  Future<ItemAvailability> availability(String itemId) => call(
    () => dio.get<dynamic>('/items/$itemId/availability'),
    (data) => ItemAvailability.fromJson(asMap(data)),
  );

  Future<Item> create({
    required String categoryId,
    required int unitsPerBox,
    required String unitLabelAr,
    required String pricePerBox,
    String? nameAr,
    String? nameEn,
    String? description,
    String? imageUrl,
    int? minQtyBoxes,
  }) {
    // Built key by key so there is exactly one visible place a new field could
    // be added — and the identity field requirement 17 forbids is not one.
    final body = <String, dynamic>{
      'categoryId': categoryId,
      'unitsPerBox': unitsPerBox,
      'unitLabelAr': unitLabelAr,
      'pricePerBox': pricePerBox,
    };
    if (nameAr != null) body['nameAr'] = nameAr;
    if (nameEn != null) body['nameEn'] = nameEn;
    if (description != null) body['description'] = description;
    if (imageUrl != null) body['imageUrl'] = imageUrl;
    // Sent in BOXES; the server stores units using the item's box size.
    if (minQtyBoxes != null) body['minQtyBoxes'] = minQtyBoxes;

    return call(
      () => dio.post<dynamic>('/admin/items', data: body),
      (data) => Item.fromJson(asMap(data)),
    );
  }

  Future<Item> update(String id, Map<String, dynamic> changes) => call(
    () => dio.patch<dynamic>('/admin/items/$id', data: changes),
    (data) => Item.fromJson(asMap(data)),
  );

  /// Deactivates. Order history must keep resolving its items.
  Future<void> deactivate(String id) =>
      call(() => dio.delete<dynamic>('/admin/items/$id'), (_) {});

  /// Uploads a picture and attaches it, replacing any before (admin).
  Future<Item> setImage(String id, List<int> bytes, String filename) => call(
    () => dio.put<dynamic>('/admin/items/$id/image', data: _pictureForm(bytes, filename)),
    (data) => Item.fromJson(asMap(data)),
  );

  Future<Item> removeImage(String id) => call(
    () => dio.delete<dynamic>('/admin/items/$id/image'),
    (data) => Item.fromJson(asMap(data)),
  );
}

/// What a search returned.
///
/// Categories come back separately because a trigger-maintained column on
/// `items` cannot reference another table, and denormalising a category path
/// onto each item would leave descendants matching the old name after every
/// rename.
class SearchResults {
  const SearchResults({required this.items, required this.categories});

  final List<Item> items;
  final List<Category> categories;

  bool get isEmpty => items.isEmpty && categories.isEmpty;
}

class SearchApi extends _CatalogApiBase {
  SearchApi(super.client);

  Future<SearchResults> search(String query, {int? limit}) => call(
    // The raw query goes out untouched. Normalisation happens in PostgreSQL,
    // by the same function that produced the stored form — pre-mangling it
    // here would reintroduce exactly the drift that design prevents.
    () => dio.get<dynamic>(
      '/search',
      queryParameters: {'q': query, if (limit != null) 'limit': limit},
    ),
    (data) {
      final map = asMap(data);
      return SearchResults(
        items: (map['items'] as List<dynamic>)
            .map((e) => Item.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        categories: (map['categories'] as List<dynamic>)
            .map((e) => Category.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );
    },
  );
}

class BatchesApi extends _CatalogApiBase {
  BatchesApi(super.client);

  Future<WarehouseBatch> receive({
    required String itemId,
    required String batchNumber,
    required DateTime expiryDate,
    required int qtyBoxes,
    String? note,
  }) {
    final body = <String, dynamic>{
      'itemId': itemId,
      'batchNumber': batchNumber,
      // YYYY-MM-DD only. Sending a full timestamp would let a timezone shift
      // the calendar date by a day.
      'expiryDate': expiryDate.toIso8601String().substring(0, 10),
      // In BOXES: the client does not know the item's box size and must not
      // guess it.
      'qtyBoxes': qtyBoxes,
    };
    if (note != null) body['note'] = note;

    return call(
      () => dio.post<dynamic>('/admin/batches', data: body),
      (data) => WarehouseBatch.fromJson(asMap(data)),
    );
  }

  Future<List<WarehouseBatch>> list({String? itemId, int? expiringWithinDays}) => call(
    () => dio.get<dynamic>(
      '/admin/batches',
      queryParameters: {
        if (itemId != null) 'itemId': itemId,
        if (expiringWithinDays != null) 'expiringWithinDays': expiringWithinDays,
      },
    ),
    (data) => (asMap(data)['batches'] as List<dynamic>)
        .map((e) => WarehouseBatch.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
  );

  Future<ItemStock> stockFor(String itemId) => call(
    () => dio.get<dynamic>('/admin/items/$itemId/stock'),
    (data) => ItemStock.fromJson(asMap(data)),
  );
}
