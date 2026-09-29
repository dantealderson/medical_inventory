import 'package:flutter_test/flutter_test.dart';
import 'package:ui_kit/ui_kit.dart';

String fmt(int units, int unitsPerBox) =>
    formatQuantity(units: units, unitsPerBox: unitsPerBox, boxLabel: 'علبة', unitLabel: 'سرنجة');

void main() {
  test('boxes and a remainder', () {
    expect(fmt(230, 100), '2 علبة + 30 سرنجة');
  });

  test('whole boxes only', () {
    expect(fmt(200, 100), '2 علبة');
  });

  test('less than a box', () {
    expect(fmt(30, 100), '30 سرنجة');
  });

  test('nothing is shown in boxes', () {
    expect(fmt(0, 100), '0 علبة');
  });

  test('a box of one', () {
    expect(fmt(7, 1), '7 علبة');
  });

  test('uses only the labels it is given', () {
    expect(
      formatQuantity(units: 150, unitsPerBox: 100, boxLabel: 'box', unitLabel: 'glove'),
      '1 box + 50 glove',
    );
  });

  test('rejects a box size that is not positive, and negative units', () {
    expect(() => fmt(10, 0), throwsArgumentError);
    expect(() => fmt(10, -5), throwsArgumentError);
    expect(() => fmt(-1, 100), throwsArgumentError);
  });
}
