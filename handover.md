# Handover

## 2026-06-25 TorBox torrent-file upload crash

- Symptom: live Mydia 0.12.0 logs showed `.torrent` submissions through the
  TorBox debrid provider crashing with `FunctionClauseError no function clause
  matching in Req.Utils.encode_form_part/2` at
  `lib/mydia/downloads/client/debrid/providers/tor_box.ex:91`.
- Root cause fixed here: TorBox built file uploads as
  `{:file, bin, filename: ..., content_type: ...}`. Req 0.6 expects multipart
  file fields as `{field, {body, opts}}` / keyword equivalent, for example
  `file: {bin, filename: "release.torrent", content_type: "application/x-bittorrent"}`.
- Regression coverage: `test/mydia/downloads/client/debrid/providers/tor_box_test.exs`
  now exercises the file-upload path through Bypass and verifies the multipart
  field, filename, content type, and payload.
- Related but not fixed by this patch: the Maya release
  `Пчёлка Майя Maya The Bee - Movie 2014 DUB BDRip 1080p` was submitted as a
  magnet to TorBox at `2026-06-25T01:03:51Z`; TorBox later reported failure and
  Mydia blacklisted that exact release as `client_reported_failure` until
  `2026-07-25T01:06:01Z`. This code fix prevents TorBox `.torrent` upload
  crashes, but provider-side magnet failures can still occur.
- Operational note: TorBox support remains marked bypass-only in code. Live
  failures should be debugged with TorBox job state, seed/peer availability,
  and Mydia download-monitor logs before assuming Kubernetes, ingress, PVC, or
  pod-health problems.

## 2026-06-25 TorBox intermittent no-seed failures

- Additional finding: TorBox can accept one release while another submitted
  release stalls or fails provider-side. Submission success only proves the
  account/API path works; it does not prove the chosen torrent is fetchable.
- Mydia previously mapped TorBox `download_state: "stalled (no seeds)"` to a
  terminal provider error. `DownloadMonitor` then saw status `"failed"`,
  deleted the queue row, and blacklisted the release immediately as
  `client_reported_failure`.
- Fix: TorBox no-seed/checking/stalled states now map to active
  `ProviderJob.state: :downloading`, matching the shared `DownloadStatus`
  taxonomy where stalled torrent downloads are still active work. The existing
  `StallDetector` can then observe lack of progress over the configured grace
  window and escalate later if it persists.
- Still terminal: TorBox `download_state: "missingFiles"` remains mapped to
  `:error`.
- Follow-up worth doing: carry provider-native failure details from
  `ProviderJob.raw_status` into the eventual `error_message`/blacklist reason
  for hard TorBox failures. Today the monitor mostly sees a generic failed
  status.
