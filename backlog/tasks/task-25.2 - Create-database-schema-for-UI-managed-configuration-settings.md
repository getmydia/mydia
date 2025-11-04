---
id: task-25.2
title: Create database schema for UI-managed configuration settings
status: Done
assignee: []
created_date: '2025-11-04 03:53'
updated_date: '2025-11-04 04:01'
labels:
  - database
  - schema
  - configuration
dependencies: []
parent_task_id: task-25
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Design and implement database tables to store configuration settings that administrators can modify through the UI. This should support general application settings, quality profiles, download client configurations, indexer configurations, and library path configurations. Settings stored in the database take precedence over config.yml but cannot override environment variables. Include audit tracking (who changed what, when) for configuration changes.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Migration creates config_settings table with key, value, category, updated_by, updated_at
- [ ] #2 Migration creates quality_profiles table (if not existing)
- [ ] #3 Migration creates download_client_configs table with connection details
- [ ] #4 Migration creates indexer_configs table with provider details
- [ ] #5 Migration creates library_paths table with path, type, monitored status
- [ ] #6 All tables use SQLite-compatible types (TEXT for UUIDs, JSON, enums)
- [ ] #7 Indexes created on frequently queried fields
- [ ] #8 Foreign keys to users table for audit tracking
- [ ] #9 Migration follows technical.md SQLite guidelines
<!-- AC:END -->
