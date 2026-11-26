# How Apple's own player lays out its controls

Gathered 2026-11-26 for `design/specs/2026-11-26-player-osd-apple-polish-design.md`.
Everything here is the Apple TV app in the "26" releases, read off Apple's own
screenshots and guide text. No screenshot of a stock third-party
`AVPlayerViewController` on iOS 26 was found, so treating it as identical is
unverified. Sizes are estimates from the screenshots; Apple publishes no
margins, capsule heights or radii for the player.

Sources:

- [iPhone guide](https://support.apple.com/guide/iphone/start-watching-and-control-playback-iphaec9fc22f/26/ios/26)
- [iPad guide](https://support.apple.com/guide/ipad/control-playback-ipad6cf12042/26/ipados/26)
- [Apple TV app on Mac guide](https://support.apple.com/guide/tvapp-mac/atv31d6caa7/mac)
- [Apple TV 4K guide](https://support.apple.com/en-ph/guide/tv/atvb7944597f/26/tvos/26)
- [9to5Mac tvOS 26 screenshot](https://9to5mac.com/2025/07/16/apples-tv-app-gets-fresh-design-in-ios-26-and-tvos-26-heres-whats-new/)
- [PCWorld tvOS 26 screenshots](https://www.pcworld.com/article/2847724/apple-tv-isnt-changing-much-in-2025.html)
- [Six Colors on tvOS 26](https://sixcolors.com/post/2025/06/tvos-26-brings-minor-additions-and-weird-priorities/)
- [HIG, Playing video](https://developer.apple.com/design/human-interface-guidelines/playing-video)
- [`AVPlayerViewController`](https://developer.apple.com/documentation/avkit/avplayerviewcontroller)

## Layout

- **Title block.** Left-aligned, directly above the scrubber, two lines: a
  small regular line on top and a large bold title below, roughly 1:2 in size.
  The top line is "S1, E2 · Episode name" on tvOS and the Mac; the iPhone and
  iPad screenshots show the episode name alone. AVKit documents
  `transportBarIncludesTitleView` as "the title view above the scrubber".
- **iPhone and iPad.** Top left: a close disc, then one capsule holding PiP,
  AirPlay and Share. Top right: a volume slider capsule. Centre: skip back 10,
  play/pause, skip forward 10. Bottom right, just above the scrubber: one
  capsule with speed, audio and subtitles. Under the scrubber: Info, InSight
  and Continue Watching capsules.
- **Mac.** The PiP/AirPlay/Share capsule sits beside the traffic lights, volume
  top right, a subtitles and audio capsule bottom right, the transport in the
  centre. No tab row.
- **tvOS.** Bottom to top: tab capsules, the timeline, then the title block on
  the left with three glass discs on the right (subtitles, audio, PiP). No
  on-screen transport buttons.

## Scrubber

- iPhone, iPad and tvOS: a thin rounded track, about 1% of the screen height,
  white played portion, translucent grey remainder, no knob.
- Mac: the same track with a round white knob.
- iPhone, iPad and Mac: elapsed at the left end and "−remaining" at the right,
  inline with the track.
- tvOS: the playhead is a thin tick slightly taller than the track; elapsed
  time sits under it and travels with it; "−remaining" is fixed under the
  right end. A preview thumbnail appears above the timeline.
- The track thickening while scrubbing is unverified.

## Transport

- Skip glyphs sit on glass discs. Play/pause is on a larger disc on iPad and
  Mac, about 1.5 times the skip discs.
- Glyphs are white: filled play and pause, outline circular-arrow "10".

## Dimming

- tvOS: an overall dim, darker toward the bottom. Six Colors: "Apple applies a
  dimming layer on everything around the controls, but not on the video
  visible through the controls".
- iPhone: only a light dim is visible; the exact treatment is unverified.

## Focus on tvOS

The focused disc turns a brighter, more opaque white; a focused menu row is a
solid white capsule with dark text. Scrubber focus is unverified.
