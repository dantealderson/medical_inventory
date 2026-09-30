import 'package:admin/core/picture_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

/// The admin gives items and categories a picture from their computer.
void main() {
  const url = '/api/v1/media/0b0c0d0e-0000-4000-8000-000000000001.webp';

  Map<String, dynamic> itemJson({String? imageUrl}) => {
    'id': 'i1',
    'nameAr': 'سرنجة 5 مل',
    'nameEn': null,
    'description': null,
    'categoryId': 'c1',
    'unitsPerBox': 100,
    'unitLabelAr': 'سرنجة',
    'unitLabelEn': null,
    'pricePerBox': '12.50',
    'imageUrl': imageUrl,
    'minQtyUnits': null,
    'minQtyBoxes': null,
    'isActive': true,
  };

  Map<String, dynamic> categoryJson({String? imageUrl}) => {
    'id': 'c1',
    'nameAr': 'مستهلكات',
    'nameEn': null,
    'parentId': null,
    'level': 1,
    'sortOrder': 0,
    'imageUrl': imageUrl,
    'isActive': true,
    'children': <dynamic>[],
  };

  final pickPhoto = picturePickerProvider.overrideWithValue(
    () async => (bytes: const [1, 2, 3], name: 'photo.png'),
  );

  Future<void> openTab(WidgetTester tester, String label) async {
    final tab = find.text(label);
    await tester.ensureVisible(tab);
    await tester.pumpAndSettle();
    await tester.tap(tab);
    await tester.pumpAndSettle();
  }

  /// The thumbnail each row loads, as an absolute URL.
  List<String> shownPictures(WidgetTester tester) => [
    for (final image in tester.widgetList<Image>(find.byType(Image)))
      if (image.image is NetworkImage) (image.image as NetworkImage).url,
  ];

  testWidgets('an item gets a picture from the computer, and shows it', (tester) async {
    String? stored;
    final backend = await pumpSignedIn(tester, (req) {
      if (req.path == '/auth/me') return [200, adminUser];
      if (req.path == '/admin/items/i1/image' && req.method == 'PUT') {
        stored = url;
        return [200, itemJson(imageUrl: stored)];
      }
      if (req.path == '/items') return [200, {'items': [itemJson(imageUrl: stored)], 'nextCursor': null}];
      return [404, null];
    }, overrides: [pickPhoto]);
    await openTab(tester, 'الأصناف');
    expect(shownPictures(tester), isEmpty);

    await tester.tap(find.text('إضافة صورة'));
    await tester.pumpAndSettle();

    expect(backend.callsTo('/admin/items/i1/image'), 1);
    expect(find.text('تم حفظ الصورة'), findsOneWidget);
    expect(shownPictures(tester), [
      'http://test.local/api/v1/media/0b0c0d0e-0000-4000-8000-000000000001.thumb.webp',
    ]);
    expect(find.text('تغيير الصورة'), findsOneWidget);
  });

  testWidgets('a refused file shows the server message', (tester) async {
    await pumpSignedIn(tester, (req) {
      if (req.path == '/auth/me') return [200, adminUser];
      if (req.path == '/admin/items/i1/image') {
        return [400, envelope(400, 'INVALID_IMAGE', 'الملف ليس صورة صالحة')];
      }
      if (req.path == '/items') return [200, {'items': [itemJson()], 'nextCursor': null}];
      return [404, null];
    }, overrides: [pickPhoto]);
    await openTab(tester, 'الأصناف');

    await tester.tap(find.text('إضافة صورة'));
    await tester.pumpAndSettle();

    expect(find.text('الملف ليس صورة صالحة'), findsOneWidget);
  });

  testWidgets('closing the file window without choosing sends nothing', (tester) async {
    final backend = await pumpSignedIn(tester, (req) {
      if (req.path == '/auth/me') return [200, adminUser];
      if (req.path == '/items') return [200, {'items': [itemJson()], 'nextCursor': null}];
      return [404, null];
    }, overrides: [picturePickerProvider.overrideWithValue(() async => null)]);
    await openTab(tester, 'الأصناف');

    await tester.tap(find.text('إضافة صورة'));
    await tester.pumpAndSettle();

    expect(backend.callsTo('/admin/items/i1/image'), 0);
  });

  testWidgets('removing a picture asks first', (tester) async {
    final backend = await pumpSignedIn(tester, (req) {
      if (req.path == '/auth/me') return [200, adminUser];
      if (req.path == '/admin/items/i1/image') return [200, itemJson()];
      if (req.path == '/items') return [200, {'items': [itemJson(imageUrl: url)], 'nextCursor': null}];
      return [404, null];
    });
    await openTab(tester, 'الأصناف');

    await tester.tap(find.text('حذف الصورة'));
    await tester.pumpAndSettle();
    expect(find.text('حذف الصورة؟'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'إلغاء'));
    await tester.pumpAndSettle();
    expect(backend.callsTo('/admin/items/i1/image'), 0);

    await tester.tap(find.text('حذف الصورة'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'حذف'));
    await tester.pumpAndSettle();

    expect(backend.lastTo('/admin/items/i1/image').method, 'DELETE');
    expect(find.text('تم حذف الصورة'), findsOneWidget);
  });

  testWidgets('a category gets a picture too', (tester) async {
    String? stored;
    final backend = await pumpSignedIn(tester, (req) {
      if (req.path == '/auth/me') return [200, adminUser];
      if (req.path == '/admin/categories/c1/image') {
        stored = url;
        return [200, categoryJson(imageUrl: stored)];
      }
      if (req.path == '/categories') return [200, [categoryJson(imageUrl: stored)]];
      return [404, null];
    }, overrides: [pickPhoto]);
    await openTab(tester, 'الأقسام');

    await tester.tap(find.text('إضافة صورة'));
    await tester.pumpAndSettle();

    expect(backend.lastTo('/admin/categories/c1/image').method, 'PUT');
    expect(shownPictures(tester), hasLength(1));
  });
}
