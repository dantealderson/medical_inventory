import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'accounts_controller.dart';
import 'catalog_controller.dart';
import 'client_inventory_controller.dart';
import 'dashboard_controller.dart';
import 'hot_deals_controller.dart';
import 'notifications_controller.dart';
import 'orders_controller.dart';
import 'settings_audit_controller.dart';

/// Reloads what others change while the admin looks away: clinics register
/// and order, and the nightly jobs move stock. Called when the browser tab
/// comes back into view. Screens keep showing what they have until the new
/// answer arrives.
void refreshServerData(WidgetRef ref) {
  ref
    ..invalidate(dashboardProvider)
    ..invalidate(accountsProvider)
    ..invalidate(ordersQueueProvider)
    ..invalidate(orderDetailProvider)
    ..invalidate(clientOrdersProvider)
    ..invalidate(clientInventoryProvider)
    ..invalidate(batchesProvider)
    ..invalidate(itemsProvider)
    ..invalidate(itemStockProvider)
    ..invalidate(categoryTreeProvider)
    ..invalidate(adminHotDealsProvider)
    ..invalidate(inboxProvider);
}
