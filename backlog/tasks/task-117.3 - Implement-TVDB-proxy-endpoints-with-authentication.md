---
id: task-117.3
title: Implement TVDB proxy endpoints with authentication
status: Done
assignee: []
created_date: '2025-11-08 03:05'
updated_date: '2025-11-08 03:42'
labels: []
dependencies: []
parent_task_id: task-117
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement proxy endpoints for TVDB API, including JWT authentication flow using a GenServer for token management. Support series search, metadata retrieval, and episode data fetching.

TVDB requires JWT token management, so implement a supervised GenServer that acquires tokens, caches them, and automatically refreshes before expiration to minimize authentication overhead.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 MetadataRelay.TVDB.Auth GenServer implemented for JWT management
- [x] #2 JWT authentication flow with token caching in GenServer state
- [x] #3 Token auto-refresh before expiration implemented
- [x] #4 Auth GenServer added to supervision tree
- [x] #5 MetadataRelay.TVDB.Client module created for API requests
- [x] #6 Series search endpoint proxies TVDB search
- [x] #7 Series metadata endpoint returns detailed series info

- [x] #8 Episode data endpoints support season and episode queries
- [x] #9 TVDB API credentials configured via environment variables
- [x] #10 Error handling covers authentication failures gracefully
<!-- AC:END -->
