import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/palette.dart';
import '../../../domain/models/media_stream.dart';
import '../../../domain/models/subtitle_format.dart';
import '../../../domain/models/subtitle_track.dart';
import '../../../l10n/l10n.dart';
import 'stream_formatters.dart';

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
    final palette = context.palette;
    if (files.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          context.l10n.mediaInfoNoFiles,
          style: TextStyle(color: palette.textSecondary),
        ),
      );
    }

    final index = selectedIndex.clamp(0, files.length - 1);
    final file = files[index];

    final video = file.ofType(MediaStreamType.video);
    final audio = file.ofType(MediaStreamType.audio);
    final subtitle = file.ofType(MediaStreamType.subtitle);
    final external = file.externalSubtitles;
    final l10n = context.l10n;

    return CustomScrollView(
      shrinkWrap: shrinkWrap,
      slivers: [
        if (files.length > 1)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
            sliver: SliverToBoxAdapter(child: _versionSwitcher(l10n, index)),
          ),
        _header('file', l10n.mediaInfoSectionFile, 1, palette),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          sliver: SliverToBoxAdapter(child: _fileBlock(file, palette)),
        ),
        if (video.isNotEmpty) ...[
          _header('video', l10n.mediaInfoSectionVideo, video.length, palette),
          _streams(
            video.length,
            (i) => _VideoStreamTile(
              key: Key('media-info-stream-${video[i].index}'),
              stream: video[i],
            ),
          ),
        ],
        if (audio.isNotEmpty) ...[
          _header('audio', l10n.mediaInfoSectionAudio, audio.length, palette),
          _streams(audio.length, (i) => _audioRow(l10n, audio[i])),
        ],
        if (subtitle.isNotEmpty || external.isNotEmpty) ...[
          _header('subtitles', l10n.commonSubtitles,
              subtitle.length + external.length, palette),
          _streams(
            subtitle.length + external.length,
            (i) => i < subtitle.length
                ? _subtitleRow(l10n, subtitle[i])
                : _externalSubtitleRow(l10n, external[i - subtitle.length]),
          ),
        ],
        if (!file.hasDetailedStreams)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
            sliver: SliverToBoxAdapter(child: _pendingNote(l10n, palette)),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  /// [id] is the stable name the header's `Key` is built from; [label] is the
  /// translated text.
  Widget _header(String id, String label, int count, MydiaPalette palette) =>
      SliverPersistentHeader(
        pinned: true,
        delegate: _SectionHeaderDelegate(
          id: id,
          label: label,
          count: count,
          background: palette.surface,
          labelColor: palette.textDisabled,
        ),
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

  Widget _versionSwitcher(AppLocalizations l10n, int index) {
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
              label: _versionChipLabel(l10n, files[i]),
              selected: i == index,
              onTap: () => onSelectVersion(i),
            ),
        ],
      ),
    );
  }

  String _versionChipLabel(AppLocalizations l10n, MediaFileInfo file) {
    final size = formatBytes(file.sizeBytes);
    // `versionLabel` falls back to an English word when the file has neither
    // resolution nor codec, so that case is named here instead.
    final label = file.resolution == null && file.codec == null
        ? l10n.mediaInfoVersionFallback
        : file.versionLabel;
    return size == null ? label : '$label · $size';
  }

  Widget _fileBlock(MediaFileInfo file, MydiaPalette palette) {
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
            style: TextStyle(
              color: palette.textPrimary,
              fontSize: 13,
              fontFamily: 'monospace',
            ),
          ),
        if (file.directory != null)
          Text(
            file.directory!,
            style: TextStyle(
              color: palette.textDisabled,
              fontSize: 12,
              fontFamily: 'monospace',
            ),
          ),
        if (summary.isNotEmpty) _DetailLine(summary.join(' · ')),
      ],
    );
  }

  /// Shown when the server has not captured detailed streams for a file yet.
  /// This is the normal state for every file in an existing library until the
  /// analysis worker's repair lane reaches it, so it reads as information
  /// rather than as an error.
  Widget _pendingNote(AppLocalizations l10n, MydiaPalette palette) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Text(
        l10n.mediaInfoStreamsPending,
        style:
            TextStyle(color: palette.textDisabled, fontSize: 12, height: 1.5),
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
    final palette = context.palette;
    final l10n = context.l10n;
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
                (stream.codec ?? l10n.commonUnknown).toUpperCase(),
                style: TextStyle(
                  color: palette.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              ..._flags(l10n).map((f) => _FlagChip(label: f)),
            ],
          ),
          const SizedBox(height: 2),
          for (final line in _videoLines(l10n)) _DetailLine(line),
        ],
      ),
    );
  }

  List<String> _flags(AppLocalizations l10n) {
    final language = l10n.languageName(stream.language);
    return [
      if (language != null) language,
      if (stream.isDefault) l10n.commonDefault,
      if (stream.isForced) l10n.mediaInfoFlagForced,
    ];
  }

  List<String> _videoLines(AppLocalizations l10n) {
    final frameRate = formatFrameRate(stream.frameRate);
    final geometry = <String>[
      if (stream.width != null && stream.height != null)
        '${stream.width} × ${stream.height}',
      if (frameRate != null) frameRate,
      if (stream.bitDepth != null) l10n.mediaInfoBitDepth(stream.bitDepth!),
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
        l10n.mediaInfoDolbyVision('${stream.dolbyVisionProfile}'),
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

  static TextStyle _codecStyle(MydiaPalette p) => TextStyle(
        color: p.textPrimary,
        fontSize: 11,
        height: 1.5,
        fontWeight: FontWeight.w600,
        fontFamily: 'monospace',
      );

  static TextStyle _valueStyle(MydiaPalette p) => TextStyle(
        color: p.textSecondary,
        fontSize: 11,
        height: 1.5,
        fontFamily: 'monospace',
      );

  static TextStyle _mutedStyle(MydiaPalette p) => TextStyle(
        color: p.textDisabled,
        fontSize: 11,
        height: 1.5,
        fontFamily: 'monospace',
      );

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final codecStyle = _codecStyle(palette);
    final valueStyle = _valueStyle(palette);
    final mutedStyle = _mutedStyle(palette);
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
                  style: mutedStyle,
                ),
              ),
              const SizedBox(width: _gap),
              SizedBox(
                width: _codecWidth,
                child: Text(
                  codec.toUpperCase(),
                  overflow: TextOverflow.ellipsis,
                  style: codecStyle,
                ),
              ),
              const SizedBox(width: _gap),
              SizedBox(
                width: _languageWidth,
                child: Text(
                  language ?? '',
                  overflow: TextOverflow.ellipsis,
                  style: valueStyle,
                ),
              ),
              const SizedBox(width: _gap),
              Expanded(
                child: Text(
                  detail,
                  overflow: TextOverflow.ellipsis,
                  style: valueStyle,
                ),
              ),
              if (flags.isNotEmpty) ...[
                const SizedBox(width: _gap),
                Text(flags.join(' · '), style: mutedStyle),
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
                style: mutedStyle,
              ),
            ),
        ],
      ),
    );
  }
}

/// Playback-affecting flags. Language is deliberately absent: it has its own
/// column in [_StreamRow], unlike the video tile where it stays a chip.
List<String> _rowFlags(AppLocalizations l10n, MediaStream stream) => [
      if (stream.isDefault) l10n.commonDefault,
      if (stream.isForced) l10n.mediaInfoFlagForced,
      if (stream.isHearingImpaired) l10n.mediaInfoFlagSdh,
      if (stream.isCommentary) l10n.mediaInfoFlagCommentary,
    ];

_StreamRow _audioRow(AppLocalizations l10n, MediaStream stream) {
  final channels = formatChannels(stream.channels, stream.channelLayout);
  final sampleRate = formatSampleRate(stream.sampleRate);
  final bitrate = formatBitrate(stream.bitrate);

  return _StreamRow(
    key: Key('media-info-stream-${stream.index}'),
    index: stream.index?.toString(),
    codec: stream.codec ?? l10n.commonUnknown,
    language: l10n.languageName(stream.language),
    detail: [
      if (channels != null) channels,
      if (sampleRate != null) sampleRate,
    ].join(' · '),
    flags: _rowFlags(l10n, stream),
    extra: [
      if (stream.title != null) stream.title!,
      if (bitrate != null) bitrate,
      if (stream.bitDepth != null) l10n.mediaInfoBitDepth(stream.bitDepth!),
    ],
  );
}

String _subtitleKind(AppLocalizations l10n, String? format) =>
    isImageSubtitleFormat(format)
        ? l10n.mediaInfoSubtitleImage
        : l10n.mediaInfoSubtitleText;

_StreamRow _subtitleRow(AppLocalizations l10n, MediaStream stream) {
  return _StreamRow(
    key: Key('media-info-stream-${stream.index}'),
    index: stream.index?.toString(),
    codec: stream.codec ?? l10n.commonUnknown,
    language: l10n.languageName(stream.language),
    detail: _subtitleKind(l10n, stream.codec),
    flags: _rowFlags(l10n, stream),
    extra: [if (stream.title != null) stream.title!],
  );
}

_StreamRow _externalSubtitleRow(AppLocalizations l10n, SubtitleTrack track) {
  return _StreamRow(
    key: Key('media-info-external-${track.id}'),
    index: null,
    codec: track.format,
    language: l10n.languageName(track.language),
    detail: _subtitleKind(l10n, track.format),
    flags: [l10n.mediaInfoFlagExternal],
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
      style: TextStyle(
        color: context.palette.textSecondary,
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
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: palette.surfaceVariant,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '$index',
        style: TextStyle(color: palette.textDisabled, fontSize: 10),
      ),
    );
  }
}

class _FlagChip extends StatelessWidget {
  final String label;

  const _FlagChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: palette.border),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        style: TextStyle(color: palette.textSecondary, fontSize: 10),
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
    final palette = context.palette;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.radiusBadge),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? palette.primary : Colors.transparent,
          border: Border.all(
            color: selected ? palette.primary : palette.border,
          ),
          borderRadius: BorderRadius.circular(AppTheme.radiusBadge),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? palette.onPrimary : palette.textSecondary,
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
/// It paints the palette's surface ([background]) rather than sitting
/// transparent so rows do not show through it once pinned. The colours are
/// fields so a preset change rebuilds the pinned header.
class _SectionHeaderDelegate extends SliverPersistentHeaderDelegate {
  final String id;
  final String label;
  final int count;
  final Color background;
  final Color labelColor;

  const _SectionHeaderDelegate({
    required this.id,
    required this.label,
    required this.count,
    required this.background,
    required this.labelColor,
  });

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
      key: Key('media-info-header-$id'),
      height: _height,
      color: background,
      alignment: Alignment.bottomLeft,
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: labelColor,
          fontSize: 10,
          letterSpacing: 1.6,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_SectionHeaderDelegate oldDelegate) =>
      oldDelegate.id != id ||
      oldDelegate.label != label ||
      oldDelegate.count != count ||
      oldDelegate.background != background ||
      oldDelegate.labelColor != labelColor;
}
