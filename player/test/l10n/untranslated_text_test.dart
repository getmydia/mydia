import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'untranslated_text_scanner.dart';

/// Converted to `context.l10n`. Literal English added under these paths
/// fails here; converting a screen means adding its path. See
/// docs/l10n.md.
const convertedPaths = <String>[
  'lib/presentation/screens/settings',
  'lib/presentation/widgets/language_picker.dart',
  'lib/presentation/screens/login_screen.dart',
  'lib/presentation/screens/login',
  'lib/core/startup/startup_error_app.dart',
  'lib/presentation/widgets/airplay_button.dart',
  'lib/presentation/widgets/ambient_backdrop.dart',
  'lib/presentation/widgets/ambient_backdrop_provider.dart',
  'lib/presentation/widgets/app_shell.dart',
  'lib/presentation/widgets/artwork_image.dart',
  'lib/presentation/widgets/audio_track_selector.dart',
  'lib/presentation/widgets/banner_button.dart',
  'lib/presentation/widgets/browse_grid.dart',
  'lib/presentation/widgets/browse_scaffold.dart',
  'lib/presentation/widgets/cast_actions.dart',
  'lib/presentation/widgets/cast_button.dart',
  'lib/presentation/widgets/cast_controls_sheet.dart',
  'lib/presentation/widgets/cast_device_picker.dart',
  'lib/presentation/widgets/cast_mini_controller.dart',
  'lib/presentation/widgets/cast_rail.dart',
  'lib/presentation/widgets/cast_subtitle_sheet.dart',
  'lib/presentation/widgets/cast_visuals.dart',
  'lib/presentation/widgets/cert_trust_dialog.dart',
  'lib/presentation/widgets/channel_badge.dart',
  'lib/presentation/widgets/collection_card.dart',
  'lib/presentation/widgets/compatibility_banner.dart',
  'lib/presentation/widgets/compatibility_details_dialog.dart',
  'lib/presentation/widgets/connection_status_dot.dart',
  'lib/presentation/widgets/connection_tone_color.dart',
  'lib/presentation/widgets/detail_action_row.dart',
  'lib/presentation/widgets/detail_art_image.dart',
  'lib/presentation/widgets/detail_hero_app_bar.dart',
  'lib/presentation/widgets/download_dialog.dart',
  'lib/presentation/widgets/episode_download_button.dart',
  'lib/presentation/widgets/episode_rail_card.dart',
  'lib/presentation/widgets/episode_rail.dart',
  'lib/presentation/widgets/focus_highlight.dart',
  'lib/presentation/widgets/freshness_header.dart',
  'lib/presentation/widgets/gesture_controls.dart',
  'lib/presentation/widgets/glass_surface.dart',
  'lib/presentation/widgets/glass',
  'lib/presentation/widgets/hero_play_control.dart',
  'lib/presentation/widgets/hls_quality_selector.dart',
  'lib/presentation/widgets/horizontal_rail.dart',
  'lib/presentation/widgets/horizontal_wheel_scroll.dart',
  'lib/presentation/widgets/local_network_settings_button.dart',
  'lib/presentation/widgets/media_card.dart',
  'lib/presentation/widgets/media_context_menu.dart',
  'lib/presentation/widgets/media_info',
  'lib/presentation/widgets/media_poster.dart',
  'lib/presentation/widgets/movie_watched_controls.dart',
  'lib/presentation/widgets/mydia_logo.dart',
];

void main() {
  test('converted code has no literal English', () {
    final found = <UntranslatedLiteral>[];
    for (final path in convertedPaths) {
      final entity = FileSystemEntity.typeSync(path);
      expect(entity, isNot(FileSystemEntityType.notFound), reason: path);
      final files = entity == FileSystemEntityType.directory
          ? Directory(path)
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))
          : [File(path)];
      for (final f in files) {
        found.addAll(findUntranslated(f.readAsStringSync(), path: f.path));
      }
    }
    expect(
      found,
      isEmpty,
      reason: 'Move these strings to lib/l10n/app_en.arb:\n${found.join('\n')}',
    );
  });
}
