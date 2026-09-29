/// Display formats shared by the Phase 3 admin screens.
///
/// Hand-rolled rather than intl's DateFormat: a pattern made only of digits
/// gains nothing from a locale. Digits stay Western until the Phase 7 RTL
/// audit (D14), and intl's `ar` locale emits Western digits anyway.
library;

/// A server instant (sent as UTC, `…Z`) as the admin's wall-clock time.
///
/// `toLocal()` is the point. Printing the UTC fields would date an order
/// placed at 01:30 in Baghdad on the previous day.
String formatTimestamp(DateTime instant) {
  final t = instant.toLocal();
  return '${formatCalendarDate(t)} ${_two(t.hour)}:${_two(t.minute)}';
}

/// A calendar date (an expiry) as YYYY-MM-DD, printed from its own fields.
///
/// Never converted between zones: the API sends a bare date precisely so no
/// timezone can move it by a day.
String formatCalendarDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${_two(date.month)}-${_two(date.day)}';

String _two(int n) => n.toString().padLeft(2, '0');
