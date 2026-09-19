/// Which subtitle formats carry bitmaps rather than text.
library;

/// Both spellings the player meets. The server normalizes a track's format
/// (`pgs`, `vobsub`) and passes the rest through as ffprobe names them
/// (`dvb_subtitle`, `xsub`); ffprobe and mpv report codecs by their own
/// names (`hdmv_pgs_subtitle`, `dvd_subtitle`).
const Set<String> _imageSubtitleFormats = {
  'pgs',
  'vobsub',
  'hdmv_pgs_subtitle',
  'dvd_subtitle',
  'dvb_subtitle',
  'xsub',
};

/// Whether [format] is a bitmap subtitle format. Only mpv can draw one;
/// media_kit's Flutter overlay renders text alone.
bool isImageSubtitleFormat(String? format) =>
    format != null && _imageSubtitleFormats.contains(format.toLowerCase());
