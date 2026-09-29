import 'package:admin/core/formatting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a calendar date prints its own fields, never shifted by a zone', () {
    // An expiry is a DATE. Converting it between zones is how 2027-03-01
    // becomes 2027-02-28 on a screen west of UTC.
    expect(formatCalendarDate(DateTime.parse('2027-03-01')), '2027-03-01');
    expect(formatCalendarDate(DateTime.utc(2027, 3, 1)), '2027-03-01');
  });

  test('a timestamp prints wall-clock time, zero-padded', () {
    expect(formatTimestamp(DateTime(2026, 9, 8, 7, 5)), '2026-09-08 07:05');
  });

  test('a UTC instant is shown in local time', () {
    // Fails for the right reason on any machine not set to UTC: without
    // toLocal() the UTC fields are printed, which in Baghdad dates an order
    // placed at 01:30 on the previous day.
    final instant = DateTime.utc(2026, 9, 27, 22, 30);
    expect(formatTimestamp(instant), formatTimestamp(instant.toLocal()));
  });
}
