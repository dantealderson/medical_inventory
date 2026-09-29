/// A quantity of base units in boxes plus loose units (spec §7.1):
/// 230 units at 100 per box is "2 علبة + 30 سرنجة".
///
/// Only the labels passed in are used, so this works for any item, any unit
/// word and either app, with no strings of its own. Digits stay Western
/// (D14): the Arabic-Indic formatter is a Phase 7 decision.
///
/// - A zero part is left out: "2 علبة", "30 سرنجة".
/// - Zero units is `0` and the box label, so an empty line still reads as a quantity.
String formatQuantity({
  required int units,
  required int unitsPerBox,
  required String boxLabel,
  required String unitLabel,
}) {
  if (unitsPerBox <= 0) {
    // A zero box size would divide by zero; a negative one is a corrupt item.
    throw ArgumentError.value(unitsPerBox, 'unitsPerBox', 'must be positive');
  }
  if (units < 0) {
    throw ArgumentError.value(units, 'units', 'must not be negative');
  }
  if (units == 0) return '0 $boxLabel';

  final boxes = units ~/ unitsPerBox;
  final remainder = units % unitsPerBox;
  if (remainder == 0) return '$boxes $boxLabel';
  if (boxes == 0) return '$remainder $unitLabel';
  return '$boxes $boxLabel + $remainder $unitLabel';
}
