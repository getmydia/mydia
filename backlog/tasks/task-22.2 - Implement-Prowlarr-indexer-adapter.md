---
id: task-22.2
title: Implement Prowlarr indexer adapter
status: Done
assignee: []
created_date: '2025-11-04 03:36'
updated_date: '2025-11-04 12:59'
labels:
  - search
  - indexers
  - prowlarr
  - backend
dependencies:
  - task-22.1
parent_task_id: task-22
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement an indexer adapter for Prowlarr using its REST API. Prowlarr is an indexer aggregator that provides a unified interface to hundreds of torrent indexers and trackers, making it the most powerful option for comprehensive search coverage.

The adapter should authenticate using API keys, search across all enabled indexers in Prowlarr, and parse the standardized Torznab/Newznab response format. This is the highest priority indexer integration as it provides access to many indexers through a single integration.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Adapter authenticates using Prowlarr API key in headers
- [x] #2 Search queries use Prowlarr's /api/v1/search endpoint
- [x] #3 Torznab/Newznab XML responses are parsed correctly
- [x] #4 Results include all standard fields (guid, title, size, seeders, download link)
- [x] #5 Quality information is extracted from torznab attributes and release names
- [x] #6 Indexer source is tracked for each result from Prowlarr
- [ ] #7 Integration tests verify search against a real Prowlarr instance
- [x] #8 Error responses are handled gracefully with appropriate error types
<!-- AC:END -->
