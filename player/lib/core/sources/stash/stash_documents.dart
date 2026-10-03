/// The Stash GraphQL documents this app sends. Hand-written: Stash's schema
/// is not vendored here, and the app uses a small, stable subset.
///
/// These are deliberately not triple-quoted. `schema_conformance_test` scans
/// triple-quoted Dart strings and holds them to the Mydia server schema,
/// which these Stash operations are not part of.
library;

const _sceneFields = 'id title details date rating100 play_count resume_time '
    'files { id path basename duration video_codec audio_codec width height bit_rate format } '
    'paths { screenshot caption } '
    'captions { language_code caption_type } '
    'studio { name } '
    'performers { name } '
    'tags { name }';

const stashFindScenes =
    'query FindScenes(\$filter: FindFilterType, \$scene_filter: SceneFilterType) { '
    'findScenes(filter: \$filter, scene_filter: \$scene_filter) { '
    'count scenes { $_sceneFields } } }';

const stashFindScene =
    'query FindScene(\$id: ID!) { findScene(id: \$id) { $_sceneFields } }';

const stashSceneStreams =
    'query SceneStreams(\$id: ID!) { sceneStreams(id: \$id) { url mime_type label } }';

const stashSaveActivity =
    'mutation SaveActivity(\$id: ID!, \$resume_time: Float, \$playDuration: Float) { '
    'sceneSaveActivity(id: \$id, resume_time: \$resume_time, playDuration: \$playDuration) }';

const stashAddPlay =
    'mutation AddPlay(\$id: ID!) { sceneAddPlay(id: \$id) { count } }';

const stashResetPlayCount =
    'mutation ResetPlayCount(\$id: ID!) { sceneResetPlayCount(id: \$id) }';

const stashSystemStatus = 'query SystemStatus { systemStatus { status } }';
