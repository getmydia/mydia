---
id: task-25.4
title: Build configuration management LiveView with source transparency
status: Done
assignee: []
created_date: '2025-11-04 03:53'
updated_date: '2025-11-04 04:15'
labels:
  - admin
  - liveview
  - ui
  - configuration
dependencies:
  - task-25.3
parent_task_id: task-25
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Create an admin-only configuration management UI that allows administrators to view and edit settings through forms. Each setting should clearly display its current source (environment variable, database/UI override, config file, or default). Settings from environment variables are displayed as read-only with explanation. All other settings can be edited via forms, with changes persisting to the database. Include sections for general settings, quality profiles, download clients, indexers, and library paths.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 AdminConfigLive LiveView created with admin-only access
- [x] #2 Tabbed interface for different configuration categories
- [x] #3 Each setting shows visual badge indicating source (ENV=read-only, DB=editable, FILE=editable, DEFAULT=editable)
- [x] #4 Environment variable settings are read-only with tooltip explaining override precedence
- [x] #5 Forms use Ecto changesets with validation
- [x] #6 Quality profiles section with CRUD operations
- [x] #7 Download clients section with connection test capability
- [x] #8 Indexers section with health check capability
- [x] #9 Library paths section with directory validation
- [x] #10 Changes persist to database via Settings context
- [x] #11 Success/error flash messages for configuration changes
- [x] #12 UI uses DaisyUI components matching product.md vision
- [x] #13 Tests cover form submission and validation
<!-- AC:END -->
