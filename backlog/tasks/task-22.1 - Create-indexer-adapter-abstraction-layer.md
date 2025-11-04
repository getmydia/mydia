---
id: task-22.1
title: Create indexer adapter abstraction layer
status: Done
assignee: []
created_date: '2025-11-04 03:36'
updated_date: '2025-11-04 05:01'
labels:
  - search
  - indexers
  - architecture
  - backend
dependencies: []
parent_task_id: task-22
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Design and implement the core abstraction layer for indexer and search provider integrations. This includes creating an Elixir behaviour that defines the common interface all indexer adapters must implement, along with shared utilities for search result parsing, error handling, and response normalization.

The abstraction should support the operations needed across all indexer types: searching by query, parsing results into a normalized format, and testing connectivity. Search results should be normalized to a common struct with fields like title, size, seeders, leechers, download_url, quality, etc.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Behaviour module defines callbacks for search, test_connection, and get_capabilities
- [x] #2 Common SearchResult struct with normalized fields (title, size, seeders, quality, etc.)
- [x] #3 Error types defined for connection failures, rate limiting, and parsing errors
- [x] #4 Adapter registry system allows runtime selection of configured indexers
- [x] #5 Shared HTTP client configuration using Req library
- [x] #6 Quality parsing utilities extract resolution, codec, HDR info from release names
- [x] #7 Documentation includes examples of implementing a new indexer adapter
<!-- AC:END -->
