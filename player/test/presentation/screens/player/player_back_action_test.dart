// On a remote, Back is the only way out of anything, so it peels one layer
// at a time: an active scrub first, then the OSD, then the player itself.
// Everywhere else Back leaves the player, as it always has.

import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/screens/player/player_screen.dart';

void main() {
  BackAction action({
    bool directionalPrimary = true,
    bool scrubActive = false,
    bool chromeBlocksBack = false,
  }) =>
      PlayerScreen.resolveBackAction(
        directionalPrimary: directionalPrimary,
        scrubActive: scrubActive,
        chromeBlocksBack: chromeBlocksBack,
      );

  test('an active scrub is cancelled first', () {
    expect(
      action(scrubActive: true, chromeBlocksBack: true),
      BackAction.cancelScrub,
    );
  });

  test('then a visible OSD is hidden', () {
    expect(action(chromeBlocksBack: true), BackAction.hideChrome);
  });

  test('then the player pops', () {
    expect(action(), BackAction.pop);
  });

  test('off the remote tier Back always pops', () {
    expect(
      action(
        directionalPrimary: false,
        scrubActive: true,
        chromeBlocksBack: true,
      ),
      BackAction.pop,
    );
  });
}
