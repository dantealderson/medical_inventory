/// Dates as the clinic reads them: yyyy/MM/dd.
///
/// Digits stay Western, as every screen shows them today (D14). The
/// Arabic-Indic formatter is a Phase 7 decision, and it will replace this one
/// place.
library;

/// An instant from the server (UTC), on the clinic's own calendar.
String formatInstantDate(DateTime instant) => _ymd(instant.toLocal());

/// A calendar date such as an expiry. It is already a date, so it is never
/// shifted through a timezone.
String formatCalendarDate(DateTime date) => _ymd(date);

String _ymd(DateTime d) => '${d.year}/${_two(d.month)}/${_two(d.day)}';

String _two(int n) => n.toString().padLeft(2, '0');
