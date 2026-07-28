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
| 8 | Reopen the app within 12h | Mini controller reappears attached to the session |
| 9 | Reopen after 12h | No phantom session; picker behaves normally |
| 10 | Stop casting from the mini controller | Receiver stops; local playback resumes control |
| 11 | Cast to a receiver on an isolated guest wifi | Bridge retry runs; a specific error appears if it also fails |
| 12 | Deny local network permission (iOS/macOS) | Picker shows the permission message, not an empty list |
| 13 | Close the picker | Discovery stops (verify no ongoing multicast in logs) |
| 14 | Power off the receiver mid-playback | Session marked stale; a Reconnect button appears rather than dead controls |
| 15 | Cast a file the receiver cannot decode | Automatically retries with TRANSCODE and plays |

## Known limitations to confirm, not file as bugs

- Subtitles do not work on the bridge route (p2p). The picker is disabled there.
- DLNA subtitle support is best-effort and varies by TV.
- App restart on the bridge route reloads from the stored position with a
  visible blip, rather than resuming seamlessly.
- If a cast escalates to a transcode retry on the direct route after a failed
  bridge attempt, the LAN proxy stays enabled until the session is stopped.
  `CastSessionManager` only tears the proxy down in `stopCast` and in
  `startCast`'s failure rollback — a transcode retry that *succeeds* after the
  bridge attempt enabled LAN access leaves it enabled for the rest of the
  (now direct-route) session.
- `dart_cast` 0.7.3 reports both "receiver could not reach the URL" and
  "receiver could not decode the file" as the same `mediaLoadFailed` error, so
  the app cannot distinguish an unreachable server from a rejected codec from
  the exception alone. It tries the LAN bridge first (which fixes the
  unreachable case) and only escalates to a transcode if that also fails — a
  failing cast may take up to three attempts (direct → bridge → transcode)
  before reporting an error to the user.
