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
