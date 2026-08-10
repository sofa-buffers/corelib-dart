import 'dart:ffi';
import 'dart:io';

/// Process CPU time in seconds — never wall-clock, so the figure reflects the
/// cost of the code rather than OS scheduling noise (BENCH_SPEC "Timing").
///
/// BENCH_SPEC names the acceptable clocks: `clock_gettime(CLOCK_PROCESS_CPUTIME_ID)`,
/// **`clock()`**, `getrusage(RUSAGE_SELF)`, … This reads libc's `clock()`
/// through `dart:ffi` — the same clock the C and C++ ports time with, so the
/// numbers are measured the same way and not merely printed the same way. It
/// counts in `CLOCKS_PER_SEC` = 1e6 units and needs no out-parameter, so
/// reading it allocates nothing, on the Dart heap or off it.
///
/// The `/proc/self/stat` fallback below is still the *process* CPU clock, but
/// it counts in `USER_HZ` ticks — **10 ms** — and that granularity is unusable
/// for calibrating a timing batch: a batch lasting a microsecond can straddle a
/// tick boundary and appear to take a full 10 ms, which sizes the batch far too
/// small, and the measurement loop then spends its second reading the clock
/// rather than running the workload. That is not hypothetical — it is what this
/// file used to do, and it left single rows of the table wrong by more than an
/// order of magnitude from one run to the next. It stays only as the fallback
/// for a host where the symbol lookup fails.
///
/// [Stopwatch] is wall-clock and is the last resort on a non-Linux host.
class CpuClock {
  CpuClock() {
    if (_clock == null && !Platform.isLinux) _sw.start();
  }

  final Stopwatch _sw = Stopwatch();

  /// `clock_t clock(void)` — resolved once per process, not per reading.
  static final _Clock? _clock = _lookupClock();

  /// POSIX fixes `CLOCKS_PER_SEC` at 1e6 regardless of the actual resolution.
  static const double _clocksPerSec = 1e6;

  /// `USER_HZ`, the unit of the `/proc/self/stat` fallback.
  static const double _userHz = 100.0;

  static _Clock? _lookupClock() {
    // `clock_t` is `long`, which the [Long] binding below assumes is 64-bit.
    if (!Platform.isLinux || sizeOf<IntPtr>() != 8) return null;
    try {
      return DynamicLibrary.process().lookupFunction<Long Function(), _Clock>(
        'clock',
      );
    } on ArgumentError {
      return null; // no such symbol — fall back to /proc, then to wall-clock
    }
  }

  double seconds() {
    final clock = _clock;
    if (clock != null) {
      final t = clock();
      if (t >= 0) return t / _clocksPerSec;
    }
    if (!Platform.isLinux) return _sw.elapsedMicroseconds / 1e6;
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

typedef _Clock = int Function();
