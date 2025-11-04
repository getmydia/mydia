---
id: task-25.5
title: Create REST API endpoints for configuration management
status: To Do
assignee: []
created_date: '2025-11-04 03:53'
labels:
  - api
  - rest
  - configuration
dependencies:
  - task-25.3
parent_task_id: task-25
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement REST API endpoints for programmatic configuration management, allowing external tools and scripts to query and update settings. Endpoints should respect the same precedence rules as the UI and require API key authentication with admin privileges. Include endpoints for listing all settings with sources, retrieving individual settings, updating settings, and testing external service connections (download clients, indexers).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 GET /api/v1/config returns all settings with sources
- [ ] #2 GET /api/v1/config/:key returns specific setting with source
- [ ] #3 PUT /api/v1/config/:key updates setting in database
- [ ] #4 POST /api/v1/config/test-connection tests download client or indexer
- [ ] #5 DELETE /api/v1/config/:key removes database override (falls back to file/default)
- [ ] #6 Endpoints require API key with admin role
- [ ] #7 Environment variable settings return error on update attempt
- [ ] #8 API responses follow technical.md REST API design
- [ ] #9 OpenAPI/Swagger documentation generated
- [ ] #10 Tests cover authentication, authorization, and CRUD operations
<!-- AC:END -->
