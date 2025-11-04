---
id: task-22.4
title: Implement direct public indexer adapter with scraping
status: To Do
assignee: []
created_date: '2025-11-04 03:36'
updated_date: '2025-11-04 03:37'
labels:
  - search
  - indexers
  - scraping
  - backend
dependencies:
  - task-22.1
parent_task_id: task-22
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement adapters for direct integration with public torrent indexers like bitsearch.to, 1337x, The Pirate Bay, RARBG mirrors, etc. These adapters scrape the search results pages since these sites don't typically offer official APIs.

This provides a fallback option for users who don't want to run Prowlarr/Jackett, though it's more fragile due to HTML changes. Include rate limiting and user-agent rotation to avoid getting blocked. Start with 2-3 popular sites as reference implementations.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Adapters implemented for at least 2-3 popular public indexers
- [ ] #2 HTML parsing extracts title, size, seeders, leechers, magnet/torrent links
- [ ] #3 User-agent rotation prevents detection as bot
- [ ] #4 Rate limiting respects per-site limits to avoid bans
- [ ] #5 Parsing errors from HTML changes are logged but don't crash the adapter
- [ ] #6 Results are normalized to common SearchResult format
- [ ] #7 Documentation explains how to add new direct indexer adapters
- [ ] #8 Graceful degradation when sites are unreachable or change structure
<!-- AC:END -->
