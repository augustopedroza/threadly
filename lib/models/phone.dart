/// Digits-only, last 10 (tolerant of formatting and country-code prefixes).
/// The canonical key for matching a phone number across contacts, categories,
/// and conversation titles.
String normalizePhone(String raw) {
  final digits = raw.replaceAll(RegExp(r'\D'), '');
  return digits.length > 10 ? digits.substring(digits.length - 10) : digits;
}
