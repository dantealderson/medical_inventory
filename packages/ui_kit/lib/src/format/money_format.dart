/// Prices as clinics read them: whole Iraqi dinars with thousands
/// separators, «12,500 د.ع». The server sends a decimal string ("12500.00");
/// dinar fractions are not in use, so a fraction is rounded half up.
///
/// Parsed from the string's digits rather than through a double, so a large
/// total never picks up a binary rounding error. Anything that is not a plain
/// decimal is shown as it came, rather than as a wrong number.
String formatIqd(String amount) {
  final match = RegExp(r'^(-?)(\d+)(?:\.(\d*))?$').firstMatch(amount.trim());
  if (match == null) return amount;
  final negative = match.group(1)!.isNotEmpty;
  var whole = BigInt.parse(match.group(2)!);
  final fraction = match.group(3) ?? '';
  if (fraction.isNotEmpty && int.parse(fraction[0]) >= 5) whole += BigInt.one;
  final grouped = _groupThousands(whole.toString());
  final sign = negative && whole > BigInt.zero ? '-' : '';
  return '$sign$grouped $iqdSymbol';
}

/// The dinar's abbreviation, as Iraqi shops write it.
const iqdSymbol = 'د.ع';

String _groupThousands(String digits) {
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}
