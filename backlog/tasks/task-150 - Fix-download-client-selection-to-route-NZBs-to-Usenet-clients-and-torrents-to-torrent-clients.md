---
id: task-150
title: >-
  Fix download client selection to route NZBs to Usenet clients and torrents to
  torrent clients
status: Done
assignee: []
created_date: '2025-11-10 18:33'
updated_date: '2025-11-10 18:47'
labels:
  - bug
  - downloads
  - usenet
  - nzb
  - client-selection
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Problem

When downloading content from Prowlarr/indexers, the system always selects the download client with the lowest priority number, regardless of whether the content is a torrent or NZB file. This causes NZB files (Usenet downloads) to be sent to torrent clients like Transmission, which fail with "unrecognized info" errors.

## Current Behavior

1. User searches for content via Prowlarr with Usenet indexers (e.g., NZBFinder)
2. Prowlarr returns NZB results with `protocol: "usenet"`
3. User clicks download
4. System selects Transmission (torrent client, priority 1) regardless of file type
5. NZB file is sent to Transmission
6. Transmission rejects with error: "unrecognized info" / "no bencoded data to parse"

## Root Cause

The `select_client_by_priority/1` function in `lib/mydia/downloads.ex` filters by `download_type` (:torrent vs :nzb), but the `SearchResult.download_protocol` field is not being properly passed through the download flow.

**Key findings:**
- Prowlarr adapter DOES detect protocol correctly: logs show "Detected protocol: :nzb"
- SearchResult struct HAS the `download_protocol` field defined
- BUT when download is initiated, the field is `nil`
- Likely cause: Search results are cached in LiveView socket assigns before the field was added

## Expected Behavior

1. Prowlarr returns results with `protocol` field
2. Prowlarr adapter maps "usenet" → `:nzb`, "torrent" → `:torrent`
3. SearchResult stores this in `download_protocol` field
4. LiveView caches results in `@search_results_map` WITH protocol
5. User clicks download
6. System retrieves SearchResult from map (should have protocol)
7. `select_client_by_priority/1` filters clients by type:
   - NZBs → route to NZBGet/SABnzbd
   - Torrents → route to Transmission/qBittorrent
8. Download succeeds

## Implementation Status

**Completed:**
- ✅ Added `download_protocol` field to SearchResult struct
- ✅ Prowlarr adapter extracts and maps protocol field
- ✅ Client selection filters by download type (torrent vs usenet clients)
- ✅ Added logging to track protocol through the flow

**Needs Investigation:**
- ❓ Why is `download_protocol` nil when retrieved from LiveView cache?
- ❓ Are results being cached before the new field exists?
- ❓ Do we need to force cache invalidation or migrate old cached results?

## Files Modified

- `lib/mydia/indexers/search_result.ex` - Added `download_protocol` field
- `lib/mydia/indexers/adapter/prowlarr.ex` - Extract and map protocol from API
- `lib/mydia/downloads.ex` - Use protocol for client selection, filter clients by type
- `lib/mydia_web/live/search_live/index.ex` - Added logging (needs cache investigation)

## Testing Steps

1. Clear browser cache/do hard refresh
2. Search for content from Usenet indexer (e.g., "Big Buck Bunny")
3. Verify logs show:
   - "Detected protocol: :nzb" from Prowlarr adapter
   - "Storing result in map: ... protocol: :nzb" when caching
   - "Retrieved search_result from map, download_protocol: :nzb" when clicking
   - "Selected download client: Local NZBGet (type: nzbget)" 
4. Click download
5. Verify download goes to NZBGet, not Transmission
6. Test with torrent result to ensure torrents still work

## Related Tasks

- task-115: Add Usenet download support (Done) - This is a bug in that implementation
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 NZB downloads from Usenet indexers are routed to NZBGet or SABnzbd
- [ ] #2 Torrent downloads are routed to Transmission or qBittorrent
- [ ] #3 SearchResult.download_protocol field is populated correctly from Prowlarr/Jackett
- [ ] #4 Protocol is preserved through LiveView caching and retrieval
- [ ] #5 Downloads complete successfully in the correct client
- [ ] #6 No 'unrecognized info' errors from mismatched client types
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation

Fixed the download client selection logic to properly route NZBs to Usenet clients and torrents to torrent clients.

### Changes Made

1. **Enhanced file type detection** (`lib/mydia/downloads.ex:873-892`):
   - Modified `download_torrent_file/1` to return the detected file type (`:nzb` or `:torrent`) along with the file content
   - Detection checks for XML with "nzb" for NZB files, and bencoded data for torrent files

2. **Updated client communication** (`lib/mydia/downloads.ex:593-620`):
   - Modified `add_torrent_to_client/4` to extract and return the detected file type
   - Returns `{:ok, client_id, detected_type}` to pass the detected type back up the chain

3. **Implemented smart client selection** (`lib/mydia/downloads.ex:363-420`):
   - Added `select_and_add_to_client/2` helper function
   - When `download_protocol` is `nil`, the function:
     1. Selects a client based on priority
     2. Downloads the file and detects its type
     3. If the detected type doesn't match the selected client type, it re-selects the appropriate client
     4. Retries the download with the correct client
   - Added `client_type_matches?/2` to validate client/download type compatibility

4. **Updated test mocks** (`test/mydia/downloads_test.exs`):
   - Added `{:file, _body}` handler to MockAdapter
   - Updated test expectations to handle the new flow

### Flow

**Before (Broken)**:
```
User clicks download → protocol=nil → selects Transmission (priority 1) → downloads NZB → tries to add NZB to Transmission → fails
```

**After (Fixed)**:
```
User clicks download → protocol=nil → selects any client → downloads file → detects NZB → re-selects SABnzbd → adds to SABnzbd → success
```

### Fallback Strategy

The fix uses a multi-layer approach:
1. **Primary**: Use `download_protocol` from SearchResult if available (set by Prowlarr adapter)
2. **Fallback**: If nil, download the file and detect the type from content
3. **Re-select**: If client type doesn't match detected type, automatically select the correct client type

This ensures backward compatibility with cached results that don't have the protocol field populated.

### Testing

- All existing tests pass
- Download tests verify the new flow with file type detection
- Tests handle both success and connection failure scenarios
<!-- SECTION:NOTES:END -->
