---
id: task-21.5
title: Create download client configuration system
status: Done
assignee: []
created_date: '2025-11-04 03:34'
updated_date: '2025-11-04 04:12'
labels:
  - downloads
  - configuration
  - backend
dependencies:
  - task-21.1
parent_task_id: task-21
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement the configuration system for download clients that supports both YAML configuration files and environment variables. The system should allow users to configure multiple download clients with different types (qBittorrent, Transmission) and priorities.

Follow the configuration patterns shown in technical.md with runtime.exs and support for environment variable substitution.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Configuration schema supports multiple download clients as a list
- [x] #2 Each client config includes type, name, url, username, password fields
- [x] #3 Environment variables can be used for sensitive values like passwords
- [x] #4 Configuration is validated at application startup with clear error messages
- [x] #5 Runtime configuration changes are not required (restart is acceptable)
- [x] #6 Default configuration example is documented in config.yml template
- [x] #7 Configuration includes optional fields like download path and category
<!-- AC:END -->
