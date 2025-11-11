---
id: task-160.1
title: Fix SABnzbd client missing api_key in config_to_map conversion
status: Done
assignee: []
created_date: '2025-11-11 02:21'
updated_date: '2025-11-11 02:26'
labels:
  - bug
  - usenet
  - sabnzbd
dependencies: []
parent_task_id: task-160
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Problem
When SABnzbd client tries to fetch queue items, it fails with KeyError because `api_key` is missing from the config map.

## Root Cause
The `config_to_map/1` function in `lib/mydia/downloads.ex:921` doesn't include `api_key` field when converting the config struct to a map. However, SABnzbd adapter expects `config.api_key` to be present (used in `lib/mydia/downloads/client/sabnzbd.ex:403`).

Note: Task 140 fixed this issue in `admin_config_live.ex` but missed these other locations where the same pattern exists.

## Evidence
Error from GitHub issue #3:
```
** (KeyError) key :api_key not found in: %{
  port: 8080,
  type: :sabnzbd,
  options: %{},
  host: "192.168.0.2",
  password: nil,
  username: nil,
  use_ssl: false,
  url_base: nil
}
```

## Solution
Add `api_key: config.api_key` to the map in two places:
1. `lib/mydia/downloads.ex:921` (primary issue)
2. `lib/mydia/downloads/untracked_matcher.ex:209` (same issue)

Note: `lib/mydia/downloads/client_health.ex:248` already includes it correctly.

## Files to Modify
- lib/mydia/downloads.ex:921-931
- lib/mydia/downloads/untracked_matcher.ex:209-219
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 config_to_map includes api_key field in lib/mydia/downloads.ex
- [x] #2 config_to_map includes api_key field in lib/mydia/downloads/untracked_matcher.ex
- [x] #3 SABnzbd client can successfully fetch queue items without KeyError
- [x] #4 Existing tests pass
<!-- AC:END -->
