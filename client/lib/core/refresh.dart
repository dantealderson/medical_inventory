import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'catalog_controller.dart';
import 'inventory_controller.dart';
import 'notifications_controller.dart';
import 'orders_controller.dart';

/// Reloads what the supplier changes while the app sits in the background:
/// order statuses, stock after a delivery or the nightly run, prices, deals
/// and notifications. Called when the app comes back to the foreground.
/// Screens keep showing what they have until the new answer arrives.
void refreshServerData(WidgetRef ref) {
  ref
    ..invalidate(cartProvider)
    ..invalidate(inventoryProvider)
    ..invalidate(unreadCountProvider)
    ..invalidate(orderHistoryProvider)
    ..invalidate(orderProvider)
    ..invalidate(hotDealsProvider)
    ..invalidate(categoryTreeProvider)
    ..invalidate(categoryItemsProvider)
    ..invalidate(itemDetailProvider)
    ..invalidate(itemAvailabilityProvider)
    ..invalidate(searchResultsProvider);
}
