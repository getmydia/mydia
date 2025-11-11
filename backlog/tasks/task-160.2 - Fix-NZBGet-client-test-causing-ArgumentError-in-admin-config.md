---
id: task-160.2
title: Fix NZBGet client test causing ArgumentError in admin config
status: Done
assignee: []
created_date: '2025-11-11 02:21'
updated_date: '2025-11-11 02:26'
labels:
  - bug
  - usenet
  - nzbget
  - admin-ui
dependencies: []
parent_task_id: task-160
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Problem
When testing NZBGet download client connection in the admin config UI, the application crashes with ArgumentError because it tries to convert an atom to an atom.

## Root Cause
In `lib/mydia_web/live/admin_config_live/index.ex:397`, the code does:
```elixir
type: String.to_atom(client.type),
```

However, `client.type` is an `Ecto.Enum` field (defined in `lib/mydia/settings/download_client_config.ex:15`) which is already stored and retrieved as an atom (`:nzbget`), not a string. Calling `String.to_atom/1` on an atom raises ArgumentError.

## Evidence
Error from logs in GitHub issue #3:
```
ArgumentError: 1st argument: not a binary
:erlang.binary_to_atom(:nzbget)
at lib/mydia_web/live/admin_config_live/index.ex:397
```

## Solution
Remove the `String.to_atom/1` call since `client.type` is already an atom:
```elixir
# Before
type: String.to_atom(client.type),

# After
type: client.type,
```

## Files to Modify
- lib/mydia_web/live/admin_config_live/index.ex:397
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Testing NZBGet connection in admin UI does not raise ArgumentError
- [x] #2 Testing other client types (SABnzbd, transmission, qbittorrent) still works
- [x] #3 Client connection test properly validates the connection
<!-- AC:END -->
