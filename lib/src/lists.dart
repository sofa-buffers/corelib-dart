// List comparison for the generated layer. Sparse omission (MESSAGE_SPEC §5.1)
// makes a generated encoder ask "is this field still its declared default?"
// once per field, and for a list field Dart cannot answer: `==` on two `List`s
// is identity, so a freshly built list never equals its default. The comparison
// is the same for every element type, so it is written once here instead of
// being emitted into every generated file.

/// Whether [a] and [b] have the same length and pairwise `==` elements.
///
/// Works for any list the generated layer holds a field in, typed lists
/// included (`Int64List`, `Float64List` and friends all implement `List`), and
/// walks no further than the first difference.
///
/// Two IEEE-754 properties are inherited from `==` on `double` and are worth
/// naming, because this is what decides whether a field is written:
///
/// * `NaN != NaN`, so a list holding a NaN never equals its default — the field
///   is written out rather than omitted, which is the safe direction: the value
///   survives.
/// * `-0.0 == 0.0`, so a list of negative zeroes does equal an all-zero
///   default and the field is omitted, which loses the sign bit. The wire
///   format keeps `-0.0` faithfully; a *default* comparison cannot, because the
///   two are equal in the language.
bool elementsEqual<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  final n = a.length;
  if (n != b.length) return false;
  for (var i = 0; i < n; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
