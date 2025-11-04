---
id: task-23.3
title: Implement direct TMDB and TVDB provider integration
status: To Do
assignee: []
created_date: '2025-11-04 03:39'
updated_date: '2025-11-04 03:39'
labels:
  - metadata
  - tmdb
  - tvdb
  - backend
dependencies:
  - task-23.1
parent_task_id: task-23
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement direct metadata providers for TMDB (The Movie Database) and TVDB (TheTVDB) as fallback options when the metadata relay is unavailable or for users who prefer direct API access.

These providers should implement proper rate limiting, API key authentication, and respect the terms of service for each API. TMDB requires an API key, and TVDB requires both API key and JWT authentication.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 TMDB provider searches movies and TV shows via /search endpoints
- [ ] #2 TMDB provider fetches detailed metadata via /movie/{id} and /tv/{id}
- [ ] #3 TVDB provider implements JWT authentication flow
- [ ] #4 TVDB provider searches and fetches series/episodes data
- [ ] #5 Both providers handle rate limits with exponential backoff
- [ ] #6 API keys are configured via environment variables
- [ ] #7 Responses are normalized to common Metadata struct
- [ ] #8 Integration tests verify operations against real APIs with test credentials
<!-- AC:END -->
