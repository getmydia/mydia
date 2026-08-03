# Cast manual test checklist

Automated tests cover routing, state, and UI. They cannot cover real receivers,
so run this checklist against actual hardware before shipping a cast change.

## Hardware needed

- One Chromecast, Google TV, or Cast-enabled TV
- One DLNA/UPnP TV or renderer (not needed for the iOS runs)

## Matrix

Run every row on macOS, Windows, Linux, and Android. On iOS run only the
Chromecast rows: DLNA discovery needs the multicast entitlement we do not
request, so DLNA devices must not appear at all.

| # | Scenario | Expected |
|---|---|---|
| 1 | Open the picker at home | Receivers appear within ~5s, grouped by protocol |
| 2 | Cast a movie, server reachable | Plays on the receiver; app shows remote controls |
| 3 | Pause / play / seek from the app | Receiver responds within ~1s |
| 4 | Let it play 30s, check the library | Resume position updated on the item |
| 5 | Pick a subtitle track (direct route) | Subtitles appear on the receiver |
| 6 | Cast while connected over p2p | Falls back to the bridge and plays; subtitle picker is disabled with a reason |
| 7 | Kill the app mid-cast, direct route | Receiver keeps playing |
| 8 | Reopen the app within 12h | **No session is restored** (see "Session restore" below) and, critically, the receiver is *not* interrupted |
| 9 | Reopen after 12h | No phantom session; picker behaves normally |
| 10 | Stop casting from the mini controller | Receiver stops; the player screen re-initialises local playback from the current position |
| 11 | Cast to a receiver on an isolated guest wifi | Bridge retry runs; a specific error appears if it also fails |
| 12 | Deny local network permission (iOS/macOS) | Picker shows the permission message, not an empty list |
| 13 | Close the picker | Discovery stops (verify no ongoing multicast in logs); on Android the multicast lock is released with it |
| 14 | Power off the receiver mid-playback | Session marked stale; **Reconnect** re-casts that session's media (not the open screen's), **Stop casting** returns to local playback |
| 15 | Cast a file the receiver cannot decode | Automatically retries with TRANSCODE and plays |
| 16 | Open a file the local player cannot decode, then cast it | The cast button is reachable from the loading and error states, not only from a playing video |
| 17 | Cast over p2p, then stop | While casting, `LocalProxyService` is LAN-bound; after stopping, `isLanAccessible` is false again and the proxy is loopback-only |
| 18 | Cast over p2p to a Chromecast | A server-side streaming session is started for the bridge URL and ended when casting stops (check the server's session list) |
| 19 | Open the picker on a network with no receivers | After ~10s the picker says "No cast devices found" rather than spinning forever |
| 20 | Cast to receiver A, then straight to receiver B | A stops playing and is disconnected before B starts |
| 21 | Cast with a VPN connected (macOS `utun`, WireGuard) | The bridge URL uses the real LAN address, not the tunnel address |

## Session restore

The design calls for reattaching to a session left running by a previous app
launch — but only when the receiver is *still playing our media*, and never by
taking a receiver over to find that out.

`dart_cast` 0.7.3 offers no way to ask. `CastService.connect` is the only entry
point to a session, and `ChromecastSession.connect` sends `LAUNCH CC1AD845`,
which evicts whatever app the receiver is running. So
`DartCastBackend.probeReceiverContentUrl` returns null ("cannot tell"), and
`CastSessionManager.restoreSession` discards the stored session rather than
risk stopping the film someone else started on the TV.

**Practical effect:** reopening the app within 12h of a cast shows no restored
session and no mini controller. This is deliberate. The one thing to verify by
hand is the negative: reopening Mydia must never interrupt the receiver.

The probe is a seam, not dead code — a backend that can answer (hand-written
CASTV2 `GET_STATUS`, or a future dart_cast release) restores the reattach path
without touching the manager. The bridge-route reload at the stored position is
already implemented behind the same gate.

## Known limitations to confirm, not file as bugs

- Subtitles do not work on the bridge route (p2p). The picker is disabled there.
- DLNA subtitle support is best-effort and varies by TV.
- Session restore never reattaches today; see "Session restore" above.
- App restart on the bridge route would reload from the stored position with a
  visible blip, rather than resuming seamlessly — reachable only once a backend
  can probe receiver state.
- Casting cannot start while the LAN interface is genuinely unusable, and the
  bridge attempt briefly binds and unbinds the proxy to discover that: whether
  a bridge URL exists is only knowable once the proxy has been LAN-bound.
- `dart_cast` 0.7.3 reports both "receiver could not reach the URL" and
  "receiver could not decode the file" as the same `mediaLoadFailed` error, so
  the app cannot distinguish an unreachable server from a rejected codec from
  the exception alone. It tries the LAN bridge first (which fixes the
  unreachable case) and only escalates to a transcode if that also fails — a
  failing cast may take up to three attempts (direct → bridge → transcode)
  before reporting an error to the user.

## Resume

Automated coverage for the resume decision itself lives in
`resume_decision_coverage_test.dart`, one widget test per playback source. It
cannot reach real receivers, real elapsed time, or a real progress sync round
trip to the server, so run this section by hand against actual hardware.

| # | Scenario | Expected |
|---|---|---|
| 1 | Watch 20 minutes of an episode locally, stop, choose a Chromecast from the detail screen, play | Resume prompt appears, then the receiver starts at 20 minutes |
| 2 | Let it run past a progress sync (10 seconds), stop casting | **The server records roughly 20 minutes, not 0.** This is the progress-destruction guard |
| 3 | Scrub the cast to 50 minutes | A brief reload, then playback at 50 minutes, not a snap back |
| 4 | Scrub the cast back to 5 minutes, before the resume offset | A reload, then playback at 5 minutes |
| 5 | Airplane mode, play a downloaded episode, watch 10 minutes, quit, replay | Resume prompt at 10 minutes |
| 6 | Go back online | The server picks up the offline position within a few seconds |
| 7 | Repeat case 1 against a DLNA renderer | Resume with no reload, since progressive routes seek directly |

Case 2 is the one to check most carefully. A resume that looks correct on
screen, receiver playing from the right spot and all, can still report
position 0 back to the server if the sync fires before the resumed offset
takes effect. That silently erases the user's real watch history for that
title, with nothing on screen to suggest anything went wrong.
