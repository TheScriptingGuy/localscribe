import 'package:intl/intl.dart';

String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

String formatSeconds(double seconds) =>
    formatDuration(Duration(milliseconds: (seconds * 1000).round()));

String formatDate(DateTime t) => DateFormat('d MMM y, HH:mm').format(t);

/// "Today at 08:36", "Yesterday at 08:36", "30 Oct at 20:28", "30 Oct 2025".
String formatRelativeDate(DateTime t, {DateTime? now}) {
  now ??= DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final time = DateFormat('HH:mm').format(t);
  final days = today.difference(day).inDays;
  if (days == 0) return 'Today at $time';
  if (days == 1) return 'Yesterday at $time';
  if (t.year == now.year) return '${DateFormat('d MMM').format(t)} at $time';
  return DateFormat('d MMM y').format(t);
}

/// Compact length: "36s", "12m", "1h 5m".
String formatShortDuration(Duration d) {
  if (d.inMinutes == 0) return '${d.inSeconds}s';
  if (d.inHours == 0) return '${d.inMinutes}m';
  final m = d.inMinutes.remainder(60);
  return m == 0 ? '${d.inHours}h' : '${d.inHours}h ${m}m';
}
