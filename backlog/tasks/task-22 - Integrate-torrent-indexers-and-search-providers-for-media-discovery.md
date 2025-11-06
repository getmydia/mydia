---
id: task-22
title: Integrate torrent indexers and search providers for media discovery
status: Done
assignee: []
created_date: '2025-11-04 03:35'
updated_date: '2025-11-06 01:19'
labels:
  - automation
  - search
  - indexers
  - integration
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Enable Mydia to search for torrents across multiple indexers and search providers. This includes integration with indexer aggregators (Prowlarr, Jackett) and direct indexer APIs (public torrent sites like bitsearch.to, 1337x, etc.).

This is a critical automation feature for Phase 2 of the roadmap that enables unified search across all configured sources. The implementation should follow the External Service Adapters pattern with a pluggable system that makes it easy to add new indexer types. Search results should be aggregated, deduplicated, and ranked by quality/seeders.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Users can configure multiple indexers via YAML configuration or environment variables
- [x] #2 System can search across all configured indexers simultaneously
- [x] #3 Search results are aggregated and deduplicated across sources
- [x] #4 Results include quality information, seeders, size, and indexer source
- [x] #5 Indexer health and availability is monitored
- [x] #6 Failed indexer queries don't block other sources from returning results
- [x] #7 Search queries support filtering by quality, size, and other criteria
- [x] #8 Rate limiting per indexer prevents API abuse and bans
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Review (2025-11-05)

Reviewed current implementation status:

**Completed:**
- ✅ Users can configure multiple indexers via Settings/IndexerConfig
- ✅ System can search across all configured indexers simultaneously  
- ✅ Search results are aggregated and deduplicated (ReleaseRanker)
- ✅ Results include quality info, seeders, size, and indexer source
- ✅ Failed indexer queries don't block other sources (error handling in adapters)
- ✅ Search queries support filtering by quality, size, etc. (SearchLive filters)

**Still TODO:**
- ❌ AC#5: Indexer health and availability monitoring (only torrent health scoring exists)
- ❌ AC#8: Proactive rate limiting per indexer (only rate limit error detection exists)

**Implementation exists:**
- Prowlarr adapter (lib/mydia/indexers/adapter/prowlarr.ex)
- Quality parser, release ranker, search results
- Registry for pluggable adapters
- Rate limit error handling but not proactive limiting

## Task Completion (2025-11-06)

All acceptance criteria have been completed with the completion of task-22.7:

**AC#5: Indexer health and availability is monitored** - ✅ COMPLETE
- Implemented in task-22.7 via `Mydia.Indexers.Health` GenServer
- Background health checks every 3 minutes
- Caches health status with 5-minute TTL
- Tracks consecutive failures and logs alerts
- Exposed via API endpoint /api/v1/indexers
- Displayed in Settings UI with visual indicators

**AC#8: Rate limiting per indexer prevents API abuse and bans** - ✅ COMPLETE
- Implemented in task-22.7 via `Mydia.Indexers.RateLimiter` GenServer
- Proactive rate limiting using sliding window algorithm
- Configurable requests-per-minute per indexer
- Gracefully rejects requests when limit exceeded
- Calculates and returns retry_after time

This task is now fully complete. All indexer integration features have been implemented, tested, and are ready for use.
<!-- SECTION:NOTES:END -->
