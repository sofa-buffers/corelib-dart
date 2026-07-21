import 'dart:io';

// Generates a self-contained flat coverage badge SVG from an lcov report.
// Pure Dart, no dependencies. Used by the docs workflow to publish the badge to
// GitHub Pages (CORELIB_PLAN §9.2 coverage badge; §12.1 "Codecov or equivalent"
// — here a self-hosted equivalent).
//
//   dart run tool/gen_coverage_badge.dart <lcov.info> <out.svg>

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('usage: gen_coverage_badge <lcov.info> <out.svg>');
    exit(2);
  }
  final lcov = File(args[0]).readAsLinesSync();
  var lf = 0, lh = 0;
  for (final line in lcov) {
    if (line.startsWith('LF:')) lf += int.parse(line.substring(3));
    if (line.startsWith('LH:')) lh += int.parse(line.substring(3));
  }
  if (lf == 0) {
    stderr.writeln('no line data in lcov report');
    exit(1);
  }
  final pct = lh / lf * 100;
  final label = 'coverage';
  final value = '${pct.toStringAsFixed(1)}%';
  final color = pct >= 90
      ? '#4c1' // brightgreen
      : pct >= 75
          ? '#dfb317' // yellow
          : '#e05d44'; // red

  // Approximate text widths (font-size 11, ~6.5px/char + padding).
  int width(String s) => (s.length * 6.5).round() + 10;
  final lw = width(label);
  final vw = width(value);
  final total = lw + vw;
  final lx = (lw * 10) ~/ 2;
  final vx = lw * 10 + (vw * 10) ~/ 2;

  final svg = '''
<svg xmlns="http://www.w3.org/2000/svg" width="$total" height="20" role="img" aria-label="$label: $value">
  <title>$label: $value</title>
  <linearGradient id="s" x2="0" y2="100%">
    <stop offset="0" stop-color="#bbb" stop-opacity=".1"/>
    <stop offset="1" stop-opacity=".1"/>
  </linearGradient>
  <clipPath id="r"><rect width="$total" height="20" rx="3" fill="#fff"/></clipPath>
  <g clip-path="url(#r)">
    <rect width="$lw" height="20" fill="#555"/>
    <rect x="$lw" width="$vw" height="20" fill="$color"/>
    <rect width="$total" height="20" fill="url(#s)"/>
  </g>
  <g fill="#fff" text-anchor="middle" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" font-size="110" text-rendering="geometricPrecision">
    <text aria-hidden="true" x="$lx" y="150" fill="#010101" fill-opacity=".3" transform="scale(.1)" textLength="${(lw - 10) * 10}">$label</text>
    <text x="$lx" y="140" transform="scale(.1)" textLength="${(lw - 10) * 10}">$label</text>
    <text aria-hidden="true" x="$vx" y="150" fill="#010101" fill-opacity=".3" transform="scale(.1)" textLength="${(vw - 10) * 10}">$value</text>
    <text x="$vx" y="140" transform="scale(.1)" textLength="${(vw - 10) * 10}">$value</text>
  </g>
</svg>
''';
  File(args[1]).writeAsStringSync(svg.trim());
  stdout.writeln('coverage badge: $value ($lh/$lf lines) -> ${args[1]}');
}
