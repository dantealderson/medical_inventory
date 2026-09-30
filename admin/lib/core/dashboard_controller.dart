import 'package:api_client/api_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_controller.dart';

final adminDashboardApiProvider = Provider<AdminDashboardApi>((ref) {
  ref.watch(authApiProvider);
  return AdminDashboardApi(ref.watch(apiClientProvider));
});

final adminJobsApiProvider = Provider<AdminJobsApi>((ref) {
  ref.watch(authApiProvider);
  return AdminJobsApi(ref.watch(apiClientProvider));
});

/// Read again on every visit: it is the admin's "what now?" screen.
final dashboardProvider = FutureProvider.autoDispose<AdminDashboard>(
  (ref) => ref.watch(adminDashboardApiProvider).get(),
);

/// Whether the out-of-stock popup was already shown this session. Kept alive
/// for the whole session, so coming back to the dashboard does not nag.
class OutOfStockPopupShown extends Notifier<bool> {
  @override
  bool build() => false;

  void markShown() => state = true;
}

final outOfStockPopupShownProvider = NotifierProvider<OutOfStockPopupShown, bool>(
  OutOfStockPopupShown.new,
);
