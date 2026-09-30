import 'package:api_client/api_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_controller.dart';

/// Each API depends on authApiProvider so the AuthInterceptor is installed
/// before any catalog call goes out — otherwise the first request leaves
/// without a bearer token and 401s for no obvious reason.
final categoriesApiProvider = Provider<CategoriesApi>((ref) {
  ref.watch(authApiProvider);
  return CategoriesApi(ref.watch(apiClientProvider));
});

final itemsApiProvider = Provider<ItemsApi>((ref) {
  ref.watch(authApiProvider);
  return ItemsApi(ref.watch(apiClientProvider));
});

final batchesApiProvider = Provider<BatchesApi>((ref) {
  ref.watch(authApiProvider);
  return BatchesApi(ref.watch(apiClientProvider));
});

/// The full category tree, already nested by the server.
final categoryTreeProvider = FutureProvider.autoDispose<List<Category>>((ref) {
  return ref.watch(categoriesApiProvider).tree();
});

/// Which category the items screen is filtered to. `null` means all.
class ItemFilter extends Notifier<String?> {
  @override
  String? build() => null;

  void setCategory(String? categoryId) => state = categoryId;
}

final itemFilterProvider = NotifierProvider<ItemFilter, String?>(ItemFilter.new);

final itemsProvider = FutureProvider.autoDispose<List<Item>>((ref) async {
  final api = ref.watch(itemsApiProvider);
  final categoryId = ref.watch(itemFilterProvider);
  // Admins see deactivated items too, so a mistakenly deactivated item can be
  // found and reactivated rather than becoming invisible.
  final page = await api.list(categoryId: categoryId);
  return page.items;
});

/// Batches expiring within the configured warning window, earliest first.
final batchesProvider = FutureProvider.autoDispose<List<WarehouseBatch>>((ref) {
  return ref.watch(batchesApiProvider).list(expiringWithinDays: 3650);
});

final itemStockProvider = FutureProvider.autoDispose.family<ItemStock, String>((ref, itemId) {
  return ref.watch(batchesApiProvider).stockFor(itemId);
});

/// Mutations. Each invalidates what it changed so the screen reflects the
/// server rather than an optimistic guess.
class CatalogActions {
  CatalogActions(this._ref);

  final Ref _ref;

  Future<void> createCategory({
    required String nameAr,
    String? nameEn,
    String? parentId,
  }) async {
    await _ref
        .read(categoriesApiProvider)
        .create(nameAr: nameAr, nameEn: nameEn, parentId: parentId);
    _ref.invalidate(categoryTreeProvider);
  }

  Future<void> deleteCategory(String id) async {
    await _ref.read(categoriesApiProvider).delete(id);
    _ref.invalidate(categoryTreeProvider);
  }

  Future<void> createItem({
    required String categoryId,
    required int unitsPerBox,
    required String unitLabelAr,
    required String pricePerBox,
    String? nameAr,
    String? nameEn,
    int? minQtyBoxes,
  }) async {
    await _ref.read(itemsApiProvider).create(
      categoryId: categoryId,
      unitsPerBox: unitsPerBox,
      unitLabelAr: unitLabelAr,
      pricePerBox: pricePerBox,
      nameAr: nameAr,
      nameEn: nameEn,
      // In BOXES — the server converts using the item's box size.
      minQtyBoxes: minQtyBoxes,
    );
    _ref.invalidate(itemsProvider);
  }

  Future<void> deactivateItem(String id) async {
    await _ref.read(itemsApiProvider).deactivate(id);
    _ref.invalidate(itemsProvider);
  }

  Future<void> receiveBatch({
    required String itemId,
    required String batchNumber,
    required DateTime expiryDate,
    required int qtyBoxes,
  }) async {
    await _ref.read(batchesApiProvider).receive(
      itemId: itemId,
      batchNumber: batchNumber,
      expiryDate: expiryDate,
      qtyBoxes: qtyBoxes,
    );
    _ref.invalidate(batchesProvider);
    // Stock totals changed too.
    _ref.invalidate(itemStockProvider);
  }
}

final catalogActionsProvider = Provider<CatalogActions>(CatalogActions.new);
