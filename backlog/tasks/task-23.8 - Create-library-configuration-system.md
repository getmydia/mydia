---
id: task-23.8
title: Create library configuration system
status: To Do
assignee: []
created_date: '2025-11-04 03:39'
updated_date: '2025-11-04 03:39'
labels:
  - library
  - configuration
  - backend
dependencies:
  - task-23.1
parent_task_id: task-23
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement the configuration system for media libraries that supports both YAML configuration files and environment variables. Users should be able to configure multiple library paths with types (movie, tv_show), naming patterns, and scanning preferences.

Follow the configuration patterns shown in technical.md with runtime.exs. The configuration example already shows media.library_paths structure - implement the full system with validation.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Configuration schema supports multiple library paths as a list
- [ ] #2 Each library path includes path, type (movie/tv_show), and optional naming pattern
- [ ] #3 Library paths are validated at startup (existence and permissions)
- [ ] #4 Metadata provider configuration (relay URL, API keys) is supported
- [ ] #5 Scan schedule is configurable via cron expression
- [ ] #6 Environment variables can be used for paths and API keys
- [ ] #7 Default configuration example is documented in config.yml template
- [ ] #8 Invalid paths or configurations are rejected at startup with helpful messages
<!-- AC:END -->
