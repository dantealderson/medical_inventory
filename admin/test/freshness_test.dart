import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

/// What someone else changes must show when the admin looks again. Lists
/// used to keep their first answer for the whole session, so a clinic that
/// registered later never appeared in the accounts tab while the dashboard
/// counted it.
void main() {
  Map<String, dynamic> batchJson(int boxes) => {
    'id': 'b1',
    'itemId': 'i1',
    'batchNumber': 'B-1',
    'expiryDate': '2030-01-01',
    'qtyUnitsReceived': 500,
    'qtyUnitsRemaining': boxes * 100,
    'qtyBoxesRemaining': boxes,
    'remainderUnits': 0,
    'isExpired': false,
    'note': null,
  };

  Future<void> openTab(WidgetTester tester, String label) async {
    final tab = find.text(label);
    await tester.ensureVisible(tab);
    await tester.pumpAndSettle();
    await tester.tap(tab);
    await tester.pumpAndSettle();
  }

  testWidgets('a clinic that registers while the admin is elsewhere shows on the accounts tab', (
    tester,
  ) async {
    var pending = <Map<String, dynamic>>[];
    await pumpSignedIn(tester, (req) {
      if (req.path == '/auth/me') return [200, adminUser];
      if (req.path == '/admin/users') return [200, page(pending)];
      return [404, null];
    });
    await openAccountsTab(tester);
    expect(find.text('lab_new'), findsNothing);

    await openTab(tester, 'الرئيسية');
    pending = [account('u5', 'lab_new', 'PENDING')];
    await openAccountsTab(tester);

    expect(find.text('lab_new'), findsWidgets);
  });

  testWidgets('batch quantities are current each time the batches tab opens', (tester) async {
    var boxes = 3;
    await pumpSignedIn(tester, (req) {
      if (req.path == '/auth/me') return [200, adminUser];
      if (req.path == '/admin/batches') return [200, {'batches': [batchJson(boxes)]}];
      if (req.path == '/items') return [200, {'items': <dynamic>[], 'nextCursor': null}];
      return [404, null];
    });
    await openTab(tester, 'التشغيلات');
    expect(find.textContaining(': 3 '), findsOneWidget);

    await openTab(tester, 'الرئيسية');
    boxes = 1; // an order was confirmed from this batch meanwhile
    await openTab(tester, 'التشغيلات');

    expect(find.textContaining(': 1 '), findsOneWidget);
  });

  testWidgets('coming back to the browser tab refreshes what is on screen', (tester) async {
    var pending = <Map<String, dynamic>>[];
    await pumpSignedIn(tester, (req) {
      if (req.path == '/auth/me') return [200, adminUser];
      if (req.path == '/admin/users') return [200, page(pending)];
      return [404, null];
    });
    await openAccountsTab(tester);

    pending = [account('u5', 'lab_new', 'PENDING')];
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(find.text('lab_new'), findsWidgets);
  });
}
