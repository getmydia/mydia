import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/colors.dart';
import '../../../domain/models/media_stream.dart';
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

  const MediaInfoContent({
    super.key,
    required this.files,
    required this.selectedIndex,
    required this.onSelectVersion,
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

    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      children: [
        if (files.length > 1) _versionSwitcher(index),
        _fileSection(file),
        ..._streamSections(file),
        if (!file.hasDetailedStreams) _pendingNote(),
      ],
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

  Widget _fileSection(MediaFileInfo file) {
    final size = formatBytes(file.sizeBytes);
    final duration = formatDuration(file.durationSeconds);
    final bitrate = formatBitrate(file.bitrate);
    final summary = <String>[
      if (file.container != null) file.container!.toUpperCase(),
      if (size != null) size,
      if (duration != null) duration,
      if (bitrate != null) bitrate,
    ];

    return _Section(
      label: 'File',
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

  List<Widget> _streamSections(MediaFileInfo file) {
    final video = file.ofType(MediaStreamType.video);
    final audio = file.ofType(MediaStreamType.audio);
    final subtitle = file.ofType(MediaStreamType.subtitle);

    return [
      if (video.isNotEmpty)
        _Section(
          label: 'Video',
          children: [for (final s in video) _StreamTile(stream: s)],
        ),
      if (audio.isNotEmpty)
        _Section(
          label:
              'Audio · ${audio.length} ${audio.length == 1 ? 'track' : 'tracks'}',
          children: [for (final s in audio) _StreamTile(stream: s)],
        ),
      if (subtitle.isNotEmpty || file.externalSubtitles.isNotEmpty)
        _Section(
          label: 'Subtitles',
          children: [
            for (final s in subtitle) _StreamTile(stream: s),
            for (final s in file.externalSubtitles)
              _ExternalSubtitleTile(
                language: languageName(s.language) ?? s.language,
                format: s.format,
              ),
          ],
        ),
    ];
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

class _Section extends StatelessWidget {
  final String label;
  final List<Widget> children;

  const _Section({required this.label, required this.children});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: AppColors.textDisabled,
              fontSize: 10,
              letterSpacing: 1.6,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }
}

class _StreamTile extends StatelessWidget {
  final MediaStream stream;

  const _StreamTile({required this.stream});

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
          for (final line in _lines()) _DetailLine(line),
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
      if (stream.isHearingImpaired) 'SDH',
      if (stream.isCommentary) 'Commentary',
    ];
  }

  List<String> _lines() {
    switch (stream.type) {
      case MediaStreamType.video:
        return _videoLines();
      case MediaStreamType.audio:
        return _audioLines();
      case MediaStreamType.subtitle:
        return _subtitleLines();
    }
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

  List<String> _audioLines() {
    final channels = formatChannels(stream.channels, stream.channelLayout);
    final sampleRate = formatSampleRate(stream.sampleRate);
    final bitrate = formatBitrate(stream.bitrate);
    final parts = <String>[
      if (channels != null) channels,
      if (sampleRate != null) sampleRate,
      if (stream.bitDepth != null) '${stream.bitDepth}-bit',
      if (bitrate != null) bitrate,
    ];

    return [
      if (stream.title != null) stream.title!,
      if (parts.isNotEmpty) parts.join(' · '),
    ];
  }

  List<String> _subtitleLines() {
    const imageCodecs = {
      'hdmv_pgs_subtitle',
      'dvd_subtitle',
      'dvb_subtitle',
      'xsub'
    };
    final isImage = imageCodecs.contains(stream.codec?.toLowerCase());
    return [
      if (stream.title != null) stream.title!,
      isImage ? 'Image based' : 'Text based',
    ];
  }
}

class _ExternalSubtitleTile extends StatelessWidget {
  final String language;
  final String format;

  const _ExternalSubtitleTile({required this.language, required this.format});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                format.toUpperCase(),
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              _FlagChip(label: language),
              const _FlagChip(label: 'External'),
            ],
          ),
        ],
      ),
    );
  }
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
