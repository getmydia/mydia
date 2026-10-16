import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../../domain/sources/item.dart';
import 'calendar_dates.dart';

/// One row of the calendar timeline.
@immutable
sealed class TimelineItem {
  const TimelineItem();
}

/// The rule before the first day of a new month.
final class MonthDivider extends TimelineItem {
  const MonthDivider(this.month);

  /// The first of the month, at local midnight.
  final DateTime month;
}

/// One day and everything airing on it.
final class TimelineDay extends TimelineItem {
  const TimelineDay(this.day, this.entries);

  /// Local midnight.
  final DateTime day;

  /// In server order. Empty only for today, which always appears so the list
  /// has somewhere to open.
  final List<ItemSummary> entries;
}

/// The calendar listing as timeline rows: days with entries in order, today
/// always among them, and a [MonthDivider] wherever the month changes.
List<TimelineItem> buildTimeline(List<ItemSummary> entries, DateTime today) {
  final midnight = truncateToDay(today);
  final days = groupByDay(entries);

  if (!days.any((group) => isSameDay(group.key, midnight))) {
    final after = days.indexWhere((group) => group.key.isAfter(midnight));
    days.insert(
      after < 0 ? days.length : after,
      MapEntry(midnight, const <ItemSummary>[]),
    );
  }

  final items = <TimelineItem>[];
  DateTime? previous;
  for (final MapEntry(key: day, value: dayEntries) in days) {
    if (previous != null &&
        (previous.year != day.year || previous.month != day.month)) {
      items.add(MonthDivider(DateTime(day.year, day.month)));
    }
    items.add(TimelineDay(day, dayEntries));
    previous = day;
  }
  return items;
}

/// Day to whether anything on it is playable. A day with no entries is
/// absent. Feeds the month sheet's dots.
Map<DateTime, bool> daySummaries(List<ItemSummary> entries) => {
      for (final MapEntry(:key, :value) in groupByDay(entries))
        key: value.any((entry) => entry.isPlayable),
    };

/// The fixed height of every timeline row, for one width and text scale.
///
/// Fixed so the scroll offset of any day is arithmetic. A lazily built list
/// never builds a day 60 days out, so asking the laid-out element where it is
/// (`Scrollable.ensureVisible`) cannot jump there. The widgets size
/// themselves from these numbers, and their text styles set an explicit line
/// `height` to match.
class TimelineLayout {
  TimelineLayout({required double width, this.textScale = 1.0})
      : contentWidth = math.min(width, maxContentWidth);

  /// The list is centred at this width on wider screens.
  static const double maxContentWidth = 720;

  static const double leftPad = 10;
  static const double rightPad = 16;
  static const double gutterWidth = 50;
  static const double gutterGap = 10;

  /// The 1px rail left of the entries plus the 12px after it.
  static const double railPad = 13;
  static const double dayPadTop = 12;
  static const double dayPadBottom = 6;
  static const double entryGap = 10;

  /// Line boxes, at 1x text. Each text style that sits in a row uses one of
  /// these as its `height`.
  static const double titleLine = 20;
  static const double subtitleLine = 17;
  static const double weekdayLine = 16;
  static const double dayNumberLine = 28;
  static const double monthLine = 14;

  final double contentWidth;
  final double textScale;

  double get entryWidth => math.max(
        0,
        contentWidth - leftPad - gutterWidth - gutterGap - railPad - rightPad,
      );

  /// The card's picture is twice as wide as it is tall.
  double get cardImageHeight => entryWidth / 2;

  /// Title, 2px gap, subtitle. The gap scales too, which keeps the row maths
  /// to one expression and only ever over-allocates.
  double get _textBlock => (titleLine + 2 + subtitleLine) * textScale;

  /// Picture, then 10px, title, 2px, subtitle, 11px.
  double get cardHeight =>
      cardImageHeight +
      10 +
      titleLine * textScale +
      2 +
      subtitleLine * textScale +
      11;

  /// A 36px thumbnail or the two text lines, whichever is taller, plus 4px.
  double get rowHeight => math.max(36.0, _textBlock) + 4;

  double get gutterHeight => (weekdayLine + dayNumberLine) * textScale;

  /// 14px above, 6px below, one line of label.
  double get monthDividerHeight => 20 + monthLine * textScale;

  double entryHeight(ItemSummary entry) =>
      entry.isPlayable ? cardHeight : rowHeight;

  double heightOf(TimelineItem item) => switch (item) {
        MonthDivider() => monthDividerHeight,
        TimelineDay(:final entries) => dayPadTop +
            dayPadBottom +
            math.max(gutterHeight, _entriesHeight(entries)),
      };

  double _entriesHeight(List<ItemSummary> entries) {
    if (entries.isEmpty) return rowHeight;
    final heights = entries.map(entryHeight).fold(0.0, (a, b) => a + b);
    return heights + entryGap * (entries.length - 1);
  }
}

/// Where every timeline row sits, for jumping and for the month label.
class TimelineGeometry {
  TimelineGeometry(this.items, this.layout) {
    var offset = 0.0;
    for (final item in items) {
      _offsets.add(offset);
      offset += layout.heightOf(item);
    }
  }

  final List<TimelineItem> items;
  final TimelineLayout layout;
  final List<double> _offsets = [];

  double extentAt(int index) => layout.heightOf(items[index]);

  /// The height of every row together.
  double get totalExtent =>
      _offsets.isEmpty ? 0 : _offsets.last + extentAt(items.length - 1);

  /// The scroll offset that puts [day] at the top of the list: the first day
  /// on or after it, or the last day when nothing is.
  double offsetOf(DateTime day) {
    final target = truncateToDay(day);
    int? last;
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item is! TimelineDay) continue;
      last = i;
      if (!item.day.isBefore(target)) return _offsets[i];
    }
    return last == null ? 0 : _offsets[last];
  }

  /// The day showing at the top when scrolled to [offset]. A month divider
  /// counts as the day below it.
  DateTime? dayAt(double offset) {
    for (var i = 0; i < items.length; i++) {
      if (_offsets[i] + extentAt(i) <= offset) continue;
      for (var j = i; j < items.length; j++) {
        final item = items[j];
        if (item is TimelineDay) return item.day;
      }
      break;
    }
    for (final item in items.reversed) {
      if (item is TimelineDay) return item.day;
    }
    return null;
  }
}
