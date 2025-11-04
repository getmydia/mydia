---
id: task-22.6
title: Create indexer configuration system
status: Done
assignee: []
created_date: '2025-11-04 03:36'
updated_date: '2025-11-04 12:56'
labels:
  - search
  - indexers
  - configuration
  - backend
dependencies:
  - task-22.1
parent_task_id: task-22
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement the configuration system for indexers that supports both YAML configuration files and environment variables. The system should allow users to configure multiple indexers with different types (Prowlarr, Jackett, direct indexers) and priorities.

Follow the configuration patterns shown in technical.md with runtime.exs and support for environment variable substitution. Include per-indexer settings like priority, timeout, and rate limits.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Configuration schema supports multiple indexers as a list
- [ ] #2 Each indexer config includes type, name, url, api_key, and optional priority
- [ ] #3 Environment variables can be used for sensitive values like API keys
- [ ] #4 Configuration is validated at application startup with clear error messages
- [ ] #5 Per-indexer settings include timeout, rate_limit, and enabled flag
- [ ] #6 Default configuration example is documented in config.yml template
- [ ] #7 Invalid indexer types are rejected at startup with helpful messages
<!-- AC:END -->
