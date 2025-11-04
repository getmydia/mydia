---
id: task-22.7
title: Add indexer rate limiting and health monitoring
status: To Do
assignee: []
created_date: '2025-11-04 03:36'
updated_date: '2025-11-04 03:37'
labels:
  - search
  - indexers
  - monitoring
  - backend
  - api
dependencies:
  - task-22.1
  - task-22.6
parent_task_id: task-22
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement rate limiting and health check functionality for indexers. Rate limiting prevents API abuse and bans by respecting per-indexer limits. Health checks verify connectivity and track indexer reliability.

Use ETS or a simple GenServer to track request counts and timing windows per indexer. Integrate health checks with the existing Mydia.Health system and expose status via the settings UI and REST API.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Rate limiting enforces configurable requests-per-minute per indexer
- [ ] #2 Rate limit violations queue or reject requests gracefully
- [ ] #3 Health checks test connection to each configured indexer
- [ ] #4 Indexer capabilities and statistics are retrieved during health check
- [ ] #5 Health status is cached with configurable TTL to avoid excessive polling
- [ ] #6 Failed health checks are logged but don't crash the system
- [ ] #7 Health status is exposed via /api/v1/indexers endpoint
- [ ] #8 Settings UI displays indexer status with visual indicators
- [ ] #9 Repeatedly failing indexers can be automatically disabled with alerts
<!-- AC:END -->
