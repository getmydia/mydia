import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/colors.dart';
import '../../../domain/models/media_stream.dart';
import '../../../domain/models/subtitle_track.dart';
import 'stream_formatters.dart';

/// Shown when the server has not captured detailed streams for a file yet.
/// This is the normal state for every file in an existing library until the
/// analysis worker's repair lane reaches it, so it reads as information rather
/// than as an error.
const String kStreamsPendingMessage =
    'Detailed stream information has not been captured for this file yet.';

/// The Media Info readout.
///
/// Deliberately knows nothing about the container holding it, so the same
/// widget serves the bottom sheet, the wide-screen side panel, and later the
/// live playback overlay.
class MediaInfoContent extends StatelessWidget {
  final List<MediaFileInfo> files;
  final int selectedIndex;
  final ValueChanged<int> onSelectVersion;

  /// Whether the host sizes itself to this content.
  ///
  /// The side panel has a bounded height and leaves this false, so rows build
  /// lazily. The bottom sheet sizes to its content and must pass true, which
  /// forces every row to be measured. A definite sheet height would avoid that
  /// but would leave a one-stream file 78% of the screen tall.
  final bool shrinkWrap;

  const MediaInfoContent({
    super.key,
    required this.files,
    required this.selectedIndex,
    required this.onSelectVersion,
    this.shrinkWrap = false,
  });

  @override
  Widget build(BuildContext context) {
    if (files.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'No files for this title.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
      );
    }

    final index = selectedIndex.clamp(0, files.length - 1);
    final file = files[index];

    final video = file.ofType(MediaStreamType.video);
    final audio = file.ofType(MediaStreamType.audio);
    final subtitle = file.ofType(MediaStreamType.subtitle);
    final external = file.externalSubtitles;

    return CustomScrollView(
      shrinkWrap: shrinkWrap,
      slivers: [
        if (files.length > 1)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
            sliver: SliverToBoxAdapter(child: _versionSwitcher(index)),
          ),
        _header('File', 1),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          sliver: SliverToBoxAdapter(child: _fileBlock(file)),
        ),
        if (video.isNotEmpty) ...[
          _header('Video', video.length),
          _streams(
            video.length,
            (i) => _VideoStreamTile(
              key: Key('media-info-stream-${video[i].index}'),
              stream: video[i],
            ),
          ),
        ],
        if (audio.isNotEmpty) ...[
          _header('Audio', audio.length),
          _streams(audio.length, (i) => _audioRow(audio[i])),
        ],
        if (subtitle.isNotEmpty || external.isNotEmpty) ...[
          _header('Subtitles', subtitle.length + external.length),
          _streams(
            subtitle.length + external.length,
            (i) => i < subtitle.length
                ? _subtitleRow(subtitle[i])
                : _externalSubtitleRow(external[i - subtitle.length]),
          ),
        ],
        if (!file.hasDetailedStreams)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
            sliver: SliverToBoxAdapter(child: _pendingNote()),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  Widget _header(String label, int count) => SliverPersistentHeader(
        pinned: true,
        delegate: _SectionHeaderDelegate(label: label, count: count),
      );

  Widget _streams(int count, Widget Function(int index) builder) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      sliver: SliverList.builder(
        itemCount: count,
        itemBuilder: (_, index) => builder(index),
      ),
    );
  }

  Widget _versionSwitcher(int index) {
    return Padding(
      key: const Key('media-info-versions'),
      padding: const EdgeInsets.only(bottom: 16),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (var i = 0; i < files.length; i++)
            _VersionChip(
              key: Key('media-info-version-$i'),
              label: _versionChipLabel(files[i]),
              selected: i == index,
              onTap: () => onSelectVersion(i),
            ),
        ],
      ),
    );
  }

  String _versionChipLabel(MediaFileInfo file) {
    final size = formatBytes(file.sizeBytes);
    return size == null ? file.versionLabel : '${file.versionLabel} · $size';
  }

  Widget _fileBlock(MediaFileInfo file) {
    final size = formatBytes(file.sizeBytes);
    final duration = formatDuration(file.durationSeconds);
    final bitrate = formatBitrate(file.bitrate);
    final summary = <String>[
      if (file.container != null) file.container!.toUpperCase(),
      if (size != null) size,
      if (duration != null) duration,
      if (bitrate != null) bitrate,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (file.fileName != null)
          Text(
            file.fileName!,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 13,
              fontFamily: 'monospace',
            ),
          ),
        if (file.directory != null)
          Text(
            file.directory!,
            style: const TextStyle(
              color: AppColors.textDisabled,
              fontSize: 12,
              fontFamily: 'monospace',
            ),
          ),
        if (summary.isNotEmpty) _DetailLine(summary.join(' · ')),
      ],
    );
  }

  Widget _pendingNote() {
    return const Padding(
      padding: EdgeInsets.only(top: 16),
      child: Text(
        kStreamsPendingMessage,
        style:
            TextStyle(color: AppColors.textDisabled, fontSize: 12, height: 1.5),
      ),
    );
  }
}

/// A video stream, kept as a multi-line block.
///
/// There is rarely more than one, and profile, geometry, Dolby Vision profile,
/// colour primaries, colour transfer and pixel format do not fit a single row.
class _VideoStreamTile extends StatelessWidget {
  final MediaStream stream;

  const _VideoStreamTile({super.key, required this.stream});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (stream.index != null) _IndexChip(index: stream.index!),
              Text(
                (stream.codec ?? 'Unknown').toUpperCase(),
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              ..._flags().map((f) => _FlagChip(label: f)),
            ],
          ),
          const SizedBox(height: 2),
          for (final line in _videoLines()) _DetailLine(line),
        ],
      ),
    );
  }

  List<String> _flags() {
    final language = languageName(stream.language);
    return [
      if (language != null) language,
      if (stream.isDefault) 'Default',
      if (stream.isForced) 'Forced',
    ];
  }

  List<String> _videoLines() {
    final frameRate = formatFrameRate(stream.frameRate);
    final geometry = <String>[
      if (stream.width != null && stream.height != null)
        '${stream.width} × ${stream.height}',
      if (frameRate != null) frameRate,
      if (stream.bitDepth != null) '${stream.bitDepth}-bit',
    ];

    final colour = <String>[
      if (stream.colorPrimaries != null) stream.colorPrimaries!,
      if (stream.colorTransfer != null) stream.colorTransfer!,
      if (stream.pixelFormat != null) stream.pixelFormat!,
    ];

    final bitrate = formatBitrate(stream.bitrate);
    return [
      if (stream.profile != null) stream.profile!,
      if (geometry.isNotEmpty) geometry.join(' · '),
      if (stream.dolbyVisionProfile != null)
        'Dolby Vision (Profile ${stream.dolbyVisionProfile})',
      if (colour.isNotEmpty) colour.join(' · '),
      if (bitrate != null) bitrate,
    ];
  }
}

/// One audio or subtitle stream, as a single aligned line.
///
/// Fixed leading column widths are what make values line up down the list; the
/// monospace face keeps numbers aligned within a column. A second muted line
/// renders only when the stream carries data the columns cannot hold, so in a
/// 34-track remux most subtitle rows stay exactly one line tall.
class _StreamRow extends StatelessWidget {
  final String? index;
  final String codec;
  final String? language;
  final String detail;
  final List<String> flags;
  final List<String> extra;

  const _StreamRow({
    super.key,
    required this.index,
    required this.codec,
    required this.language,
    required this.detail,
    required this.flags,
    required this.extra,
  });

  static const double _indexWidth = 22;
  static const double _codecWidth = 66;
  static const double _languageWidth = 88;
  static const double _gap = 8;

  static const TextStyle _codecStyle = TextStyle(
    color: AppColors.textPrimary,
    fontSize: 11,
    height: 1.5,
    fontWeight: FontWeight.w600,
    fontFamily: 'monospace',
  );

  static const TextStyle _valueStyle = TextStyle(
    color: AppColors.textSecondary,
    fontSize: 11,
    height: 1.5,
    fontFamily: 'monospace',
  );

  static const TextStyle _mutedStyle = TextStyle(
    color: AppColors.textDisabled,
    fontSize: 11,
    height: 1.5,
    fontFamily: 'monospace',
  );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: _indexWidth,
                child: Text(
                  index ?? '',
                  textAlign: TextAlign.right,
                  style: _mutedStyle,
                ),
              ),
              const SizedBox(width: _gap),
              SizedBox(
                width: _codecWidth,
                child: Text(
                  codec.toUpperCase(),
                  overflow: TextOverflow.ellipsis,
                  style: _codecStyle,
                ),
              ),
              const SizedBox(width: _gap),
              SizedBox(
                width: _languageWidth,
                child: Text(
                  language ?? '',
                  overflow: TextOverflow.ellipsis,
                  style: _valueStyle,
                ),
              ),
              const SizedBox(width: _gap),
              Expanded(
                child: Text(
                  detail,
                  overflow: TextOverflow.ellipsis,
                  style: _valueStyle,
                ),
              ),
              if (flags.isNotEmpty) ...[
                const SizedBox(width: _gap),
                Text(flags.join(' · '), style: _mutedStyle),
              ],
            ],
          ),
          if (extra.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(
                left: _indexWidth + _codecWidth + _gap * 2,
              ),
              child: Text(
                extra.join(' · '),
                overflow: TextOverflow.ellipsis,
                style: _mutedStyle,
              ),
            ),
        ],
      ),
    );
  }
}

/// Subtitle codecs that carry bitmaps rather than text.
const Set<String> _imageSubtitleCodecs = {
  'hdmv_pgs_subtitle',
  'dvd_subtitle',
  'dvb_subtitle',
  'xsub',
};

bool _isImageSubtitle(String? codec) =>
    _imageSubtitleCodecs.contains(codec?.toLowerCase());

/// Playback-affecting flags. Language is deliberately absent: it has its own
/// column in [_StreamRow], unlike the video tile where it stays a chip.
List<String> _rowFlags(MediaStream stream) => [
      if (stream.isDefault) 'Default',
      if (stream.isForced) 'Forced',
      if (stream.isHearingImpaired) 'SDH',
      if (stream.isCommentary) 'Commentary',
    ];

_StreamRow _audioRow(MediaStream stream) {
  final channels = formatChannels(stream.channels, stream.channelLayout);
  final sampleRate = formatSampleRate(stream.sampleRate);
  final bitrate = formatBitrate(stream.bitrate);

  return _StreamRow(
    key: Key('media-info-stream-${stream.index}'),
    index: stream.index?.toString(),
    codec: stream.codec ?? 'Unknown',
    language: languageName(stream.language),
    detail: [
      if (channels != null) channels,
      if (sampleRate != null) sampleRate,
    ].join(' · '),
    flags: _rowFlags(stream),
    extra: [
      if (stream.title != null) stream.title!,
      if (bitrate != null) bitrate,
      if (stream.bitDepth != null) '${stream.bitDepth}-bit',
    ],
  );
}

_StreamRow _subtitleRow(MediaStream stream) {
  return _StreamRow(
    key: Key('media-info-stream-${stream.index}'),
    index: stream.index?.toString(),
    codec: stream.codec ?? 'Unknown',
    language: languageName(stream.language),
    detail: _isImageSubtitle(stream.codec) ? 'Image' : 'Text',
    flags: _rowFlags(stream),
    extra: [if (stream.title != null) stream.title!],
  );
}

_StreamRow _externalSubtitleRow(SubtitleTrack track) {
  return _StreamRow(
    key: Key('media-info-external-${track.id}'),
    index: null,
    codec: track.format,
    language: languageName(track.language),
    detail: _isImageSubtitle(track.format) ? 'Image' : 'Text',
    flags: const ['External'],
    extra: [if (track.title != null) track.title!],
  );
}

class _DetailLine extends StatelessWidget {
  final String text;

  const _DetailLine(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: AppColors.textSecondary,
        fontSize: 12,
        height: 1.6,
        fontFamily: 'monospace',
      ),
    );
  }
}

class _IndexChip extends StatelessWidget {
  final int index;

  const _IndexChip({required this.index});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '$index',
        style: const TextStyle(color: AppColors.textDisabled, fontSize: 10),
      ),
    );
  }
}

class _FlagChip extends StatelessWidget {
  final String label;

  const _FlagChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        style: const TextStyle(color: AppColors.textSecondary, fontSize: 10),
      ),
    );
  }
}

class _VersionChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _VersionChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.radiusBadge),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : Colors.transparent,
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
          ),
          borderRadius: BorderRadius.circular(AppTheme.radiusBadge),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? AppColors.onPrimary : AppColors.textSecondary,
            fontSize: 11,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

/// A section label that stays put while its rows scroll under it.
///
/// It paints [AppColors.surface] rather than sitting transparent so rows do not
/// show through it once pinned.
class _SectionHeaderDelegate extends SliverPersistentHeaderDelegate {
  final String label;
  final int count;

  const _SectionHeaderDelegate({required this.label, required this.count});

  static const double _height = 30;

  @override
  double get minExtent => _height;

  @override
  double get maxExtent => _height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final text = count > 1 ? '$label · $count' : label;

    return Container(
      key: Key('media-info-header-${label.toLowerCase()}'),
      height: _height,
      color: AppColors.surface,
      alignment: Alignment.bottomLeft,
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: AppColors.textDisabled,
          fontSize: 10,
          letterSpacing: 1.6,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_SectionHeaderDelegate oldDelegate) =>
      oldDelegate.label != label || oldDelegate.count != count;
}
