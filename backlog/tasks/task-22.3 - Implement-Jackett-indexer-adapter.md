---
id: task-22.3
title: Implement Jackett indexer adapter
status: To Do
assignee: []
created_date: '2025-11-04 03:36'
updated_date: '2025-11-04 03:37'
labels:
  - search
  - indexers
  - jackett
  - backend
dependencies:
  - task-22.1
parent_task_id: task-22
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement an indexer adapter for Jackett using its REST API. Jackett is another popular indexer aggregator that provides access to many torrent trackers through a unified Torznab interface.

The adapter should support both the aggregate /all endpoint (searches all indexers at once) and individual indexer endpoints. This provides an alternative to Prowlarr for users who prefer Jackett.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Adapter uses Jackett's /api/v2.0/indexers/all/results endpoint for unified search
- [ ] #2 API key is passed via query parameter as required by Jackett
- [ ] #3 Torznab XML responses are parsed using shared parsing utilities
- [ ] #4 Results are normalized to common SearchResult format
- [ ] #5 Jackett-specific fields (tracker, category) are preserved in metadata
- [ ] #6 Support for both configured API key and passthrough mode
- [ ] #7 Integration tests verify search against a real Jackett instance
<!-- AC:END -->
