# How video apps moved their player controls to Liquid Glass

Gathered 2026-11-25 for `design/specs/2026-11-25-player-osd-liquid-glass-design.md`.
Apple's HIG pages were read from their JSON
(`developer.apple.com/tutorials/data/design/human-interface-guidelines/{materials,color,buttons}.json`).
Items marked unverified had no primary source.

## Apple's system player

- iOS 26 TV app: transparent glass controls that "float above your video
  without obstructing what's happening underneath"
  ([9to5Mac](https://9to5mac.com/2025/07/16/apples-tv-app-gets-fresh-design-in-ios-26-and-tvos-26-heres-whats-new/)).
- tvOS 26: glass progress bar and buttons; glass only on the 2nd-gen Apple TV
  4K and later. The HIG has tvOS buttons adopt glass when focused.
- The HIG says AVKit's playback controls "provide their own dimming layer".
- Infuse's developer says Apple's player does not glass the seek bar
  (unverified).
- macOS 26 `AVPlayerView`: `.inline` controls draw a black slab, `.floating`
  does not ([forum](https://developer.apple.com/forums/thread/802820)).
- Safari darkens video whenever its controls show, criticised as "less focus to
  content" ([mjtsai](https://mjtsai.com/blog/2025/10/16/liquid-glass-content-vs-controls/)).

## Third-party apps

- **Infuse.** 8.x put glass on the centre buttons and the scrubber. 8.2.7
  removed it from the scrubber and toned down the buttons: moving blur was
  distracting, the glass seek bar hurt subtitle legibility, and Apple does not
  glass its own. Users in 2026 still report white glyphs with no contrast in
  bright scenes
  ([8.2.7](https://community.firecore.com/t/infuse-8-2-7-now-available/57570),
  [visibility thread](https://community.firecore.com/t/improve-controls-visibility-usability/59784)).
- **Swiftfin.** Glass behind an OS 26 check with a separate pre-26 design.
  `.buttonStyle(.glass)` rendered consistently where nested `.glassEffect` did
  not. Prominent buttons got an accent tint with Increase Contrast variants
  ([#2147](https://github.com/jellyfin/Swiftfin/pull/2147),
  [#2216](https://github.com/jellyfin/Swiftfin/pull/2216),
  [#2303](https://github.com/jellyfin/Swiftfin/pull/2303)).
- **VLC for macOS.** `NSBezelStyleGlass` capsules, plain `play.fill` and
  `pause.fill` glyphs forced white, no drop shadows, all behind
  `@available(macOS 26)`
  ([commits](https://mailman.videolan.org/pipermail/vlc-commits/2025-August/071672.html)).
- **CNN.** Glass only on iOS 26 and only on its player's button overlays
  ([WWDC Meet with Apple](https://developer.apple.com/videos/play/meet-with-apple/256)).
- **IINA.** 1.5 reportedly adds Liquid Glass with separate toggles for OSD,
  controls and sidebars (unverified,
  [coverage](https://alternativeto.net/news/2026/10/open-source-video-player-iina-1-5-launches-with-biggest-interface-redesign-in-decade/)).
- **Netflix** on Apple TV dropped the native player for its own and did not
  adopt glass
  ([9to5Mac](https://9to5mac.com/2026/04/15/netflix-ruined-its-apple-tv-app-by-switching-to-a-custom-video-player/)).
- **YouTube.** Material 3 translucent "bubble" controls; reviewers found the
  icons harder to see. Liquid Glass on iOS is only leaked flags.
- **Plex, Channels, VLC for iOS, Disney+:** no player-specific evidence found.

## Apple's rules that bear on an OSD

1. Glass is a functional layer for controls and navigation, never content.
2. Use it sparingly, on the most important elements.
3. Regular glass where legibility is at risk; clear glass only over rich media
   such as video, with a dark dimming layer of about 35% over bright content.
4. Glass takes its colour from what is behind it; prefer monochrome glyphs and
   tint only a primary action's background.
5. Capsules for buttons, rounded rectangles for larger panels.
6. Group glass in a `GlassEffectContainer` for performance and morphing.
7. Honour Reduce Transparency and Increase Contrast. iOS 26.1 added a
   Clear/Tinted setting with no public API to read it.

## Mitigations seen

Dark scrim under the controls (AVKit, Safari); no glass on the scrubber
(Infuse); white glyphs without shadows (VLC); accent tint on the primary button
with contrast variants (Swiftfin); OS-version gating with a non-glass fallback
(Swiftfin, CNN, VLC); user toggles (IINA, unverified).

## Other platforms

Material 3 Expressive uses bold shapes, larger controls and spring motion, not
translucent glass. Windows reserves Acrylic for transient flyouts. A single
translucent style everywhere would look foreign on both.

## Flutter

Shader packages (`liquid_glass_renderer`) are experimental, need Impeller, and
are costly per layer. Native-glass packages (`cupertino_native` and others)
embed UIKit or SwiftUI glass in platform views, which sit above Flutter's
surface and show through Flutter dialogs, sheets and transitions.
