import 'package:admin/features/audit/audit_changes.dart';
import 'package:admin/l10n/app_localizations.dart';
import 'package:api_client/api_client.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

AuditEntry entry(String action, {Object? before, Object? after, String? note}) => AuditEntry(
  id: 'a1',
  action: action,
  entityType: 'x',
  entityId: 'e1',
  actorId: 'adm',
  actorUsername: 'admin',
  before: before,
  after: after,
  note: note,
  createdAt: DateTime.utc(2027, 1, 20),
);

void main() {
  final l10n = lookupAppLocalizations(const Locale('ar'));
  List<String> lines(AuditEntry e) => auditChanges(l10n, e);

  test('a setting reads by its label, from old to new', () {
    expect(lines(entry('SETTINGS_CHANGED', before: {'stock.redDaysOfCover': 7}, after: {'stock.redDaysOfCover': 5})), [
      'أحمر إذا كان المخزون يكفي أقل من (يوم): من 7 إلى 5',
    ]);
  });

  test('a price reads in dinars; what did not change is left out', () {
    expect(
      lines(entry('ITEM_UPDATED', before: {'pricePerBox': '3000', 'isActive': true}, after: {'pricePerBox': '4500', 'isActive': true})),
      ['سعر العلبة: من 3,000 د.ع إلى 4,500 د.ع'],
    );
  });

  test('an account status reads in words', () {
    expect(lines(entry('CLIENT_SUSPENDED', before: {'status': 'ACTIVE'}, after: {'status': 'SUSPENDED'})), [
      'الحالة: من مفعّل إلى موقوف',
    ]);
  });

  test('a new record lists what it holds, without ids', () {
    expect(
      lines(entry('BATCH_RECEIVED', after: {'itemId': 'f3f0-uuid', 'batchNumber': 'A2391', 'expiryDate': '2027-08-01', 'qtyUnitsReceived': 30})),
      ['رقم التشغيلة: A2391', 'تاريخ انتهاء الصلاحية: 2027-08-01', 'الكمية المستلمة (وحدة): 30'],
    );
  });

  test('a confirmed order says what was approved per line, no line ids', () {
    final out = lines(entry(
      'ORDER_CONFIRMED',
      before: {'lines': [{'orderLineId': 'uuid-1', 'qtyBoxesRequested': 3}, {'orderLineId': 'uuid-2', 'qtyBoxesRequested': 2}]},
      after: {
        'lines': [
          {'orderLineId': 'uuid-1', 'qtyBoxesApproved': 2, 'qtyUnitsFulfilled': 200},
          {'orderLineId': 'uuid-2', 'qtyBoxesApproved': 2, 'qtyUnitsFulfilled': 40},
        ],
        'totalAmount': '28000.00',
      },
    ));
    expect(out, ['المعتمد: 2 من 3 علبة، 2 من 2 علبة', 'الإجمالي: 28,000 د.ع']);
    expect(out.join(), isNot(contains('uuid')));
  });

  test('a cancelled order gives where it was, the reason and where the goods went', () {
    expect(
      lines(entry('ORDER_CANCELLED', after: {'from': 'OUT_FOR_DELIVERY', 'reason': 'رفض الاستلام', 'disposition': 'RETURNED_TO_WAREHOUSE', 'releasedUnits': 200})),
      ['ألغي وهو: قيد التوصيل', 'سبب الإلغاء: رفض الاستلام', 'مصير البضاعة: أُعيدت إلى المستودع', 'الوحدات المعادة: 200'],
    );
  });

  test('a yes/no reads as words', () {
    expect(lines(entry('ITEM_DEACTIVATED', before: {'isActive': true}, after: {'isActive': false})), ['مفعّل: من نعم إلى لا']);
  });

  test('an English note from the server is left out; an Arabic one is kept', () {
    expect(lines(entry('PASSWORD_RESET', note: 'Password reset by admin; all sessions revoked')), isEmpty);
    expect(lines(entry('X', note: 'ملاحظة')), ['ملاحظة']);
  });

  test('a field it does not know is still shown, never hidden', () {
    expect(lines(entry('X', after: {'somethingNew': 'v'})), ['somethingNew: v']);
  });
}
