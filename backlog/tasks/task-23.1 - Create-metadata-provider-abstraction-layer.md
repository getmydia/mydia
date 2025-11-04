---
id: task-23.1
title: Create metadata provider abstraction layer
status: Done
assignee: []
created_date: '2025-11-04 03:39'
updated_date: '2025-11-04 16:02'
labels:
  - metadata
  - architecture
  - backend
dependencies: []
parent_task_id: task-23
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Design and implement the core abstraction layer for metadata provider integrations. This includes creating an Elixir behaviour that defines the common interface all metadata providers must implement, along with shared utilities for caching, error handling, and response normalization.

The abstraction should support operations needed across all metadata sources: searching by title/year, fetching by ID, retrieving images, and handling rate limits. Metadata should be normalized to a common struct that maps to the media_items schema.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Behaviour module defines callbacks for search, fetch_by_id, fetch_images, and test_connection
- [x] #2 Common Metadata struct with normalized fields (title, description, year, cast, etc.)
- [x] #3 Error types defined for connection failures, rate limiting, and not found errors
- [x] #4 Provider registry system allows runtime selection of configured providers
- [x] #5 Shared HTTP client configuration using Req library
- [x] #6 Caching strategy for metadata to reduce API calls
- [x] #7 Documentation includes examples of implementing a new metadata provider
<!-- AC:END -->
