---
id: task-21.6
title: Add download client health checks and status reporting
status: Done
assignee: []
created_date: '2025-11-04 03:34'
updated_date: '2025-11-04 19:18'
labels:
  - downloads
  - monitoring
  - backend
  - api
dependencies:
  - task-21.1
  - task-21.5
parent_task_id: task-21
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement health check functionality for download clients that verifies connectivity and reports status. This should integrate with the existing Phoenix health check system and provide visibility into download client availability.

Health checks should run periodically and expose status via the settings UI and REST API.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Health check tests connection to each configured download client
- [x] #2 Client version and capabilities are retrieved during health check
- [x] #3 Health status is cached to avoid excessive polling
- [x] #4 Failed health checks log appropriate warnings without crashing
- [x] #5 Health status is exposed via /api/v1/downloads/clients endpoint
- [x] #6 Settings UI displays download client status with visual indicators
- [x] #7 Health checks integrate with existing Mydia.Health system
<!-- AC:END -->
