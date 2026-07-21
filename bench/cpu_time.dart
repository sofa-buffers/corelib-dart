import 'dart:io';

/// Process CPU time in seconds (BENCH_SPEC: measure over process/thread CPU
/// time, never wall-clock). On Linux we read `utime`+`stime` from
/// `/proc/self/stat` (clock ticks, USER_HZ = 100). Falls back to a wall-clock
/// [Stopwatch] elsewhere.
class CpuClock {
  CpuClock() : _linux = Platform.isLinux {
    if (!_linux) _sw.start();
  }

  final bool _linux;
  final Stopwatch _sw = Stopwatch();
  static const double _userHz = 100.0;

  double seconds() {
    if (!_linux) return _sw.elapsedMicroseconds / 1e6;
    final stat = File('/proc/self/stat').readAsStringSync();
    // Fields after the final ')' (comm may contain spaces/parens): field 3
    // (state) onward. utime = field 14, stime = field 15.
    final rest = stat.substring(stat.lastIndexOf(')') + 2).trim();
    final parts = rest.split(RegExp(r'\s+'));
    final utime = int.parse(parts[11]);
    final stime = int.parse(parts[12]);
    return (utime + stime) / _userHz;
  }
}
