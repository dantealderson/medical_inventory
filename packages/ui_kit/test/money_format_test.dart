import 'package:flutter_test/flutter_test.dart';
import 'package:ui_kit/ui_kit.dart';

void main() {
  group('formatIqd', () {
    test('whole dinars with thousands separators and the symbol', () {
      expect(formatIqd('12500.00'), '12,500 د.ع');
      expect(formatIqd('77500'), '77,500 د.ع');
      expect(formatIqd('1234567.00'), '1,234,567 د.ع');
    });

    test('small amounts have no separator', () {
      expect(formatIqd('0.00'), '0 د.ع');
      expect(formatIqd('500.00'), '500 د.ع');
    });

    test('a fraction is rounded half up', () {
      expect(formatIqd('999.50'), '1,000 د.ع');
      expect(formatIqd('999.49'), '999 د.ع');
    });

    test('a huge total stays exact', () {
      expect(formatIqd('9999999999999999.00'), '9,999,999,999,999,999 د.ع');
    });

    test('anything else is shown as it came', () {
      expect(formatIqd(''), '');
      expect(formatIqd('abc'), 'abc');
    });
  });
}
