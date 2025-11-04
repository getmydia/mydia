---
id: task-31.5
title: Write integration tests for add-to-library workflow
status: To Do
assignee: []
created_date: '2025-11-04 21:23'
labels:
  - testing
  - backend
dependencies:
  - task-20
parent_task_id: task-31
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Create comprehensive integration tests for the complete add-to-library flow from search results.

**Test Coverage:**
- Successful movie addition (parse → search → fetch → create)
- Successful TV show addition with episode creation
- Multi-episode release handling
- Duplicate detection (existing TMDB ID)
- Parse failure scenarios
- No metadata matches found
- Metadata provider API errors
- Low confidence parsing with fallback
- Year matching in metadata search

**Test Files:**
- `test/mydia_web/live/search_live/add_to_library_test.exs`
- Mock metadata provider responses
- Mock FileParser results
- Verify MediaItem and Episode creation
- Verify navigation and flash messages

**Prerequisites:**
- Fix test infrastructure (task-20) if not already done
- Create test fixtures for metadata responses
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Tests cover happy path for movies
- [ ] #2 Tests cover happy path for TV shows with episodes
- [ ] #3 Tests cover all error scenarios
- [ ] #4 Tests verify duplicate detection
- [ ] #5 Tests mock metadata provider responses
- [ ] #6 All tests pass in CI/local environment
- [ ] #7 Test coverage > 80% for new code
<!-- AC:END -->
