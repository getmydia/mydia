---
id: task-24
title: Create Oban background jobs monitoring and management UI
status: Done
assignee:
  - '@assistant'
created_date: '2025-11-04 03:41'
updated_date: '2025-11-04 03:49'
labels:
  - oban
  - ui
  - monitoring
  - liveview
dependencies:
  - task-8
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Build a LiveView-based UI for monitoring and managing Oban background jobs. This provides visibility into scheduled jobs, job history, execution status, and allows administrators to manually trigger jobs or view job details.

The UI should show all configured cron jobs (library scanner, download monitor, automated searcher, etc.) with their schedules, last run time, next run time, and execution history. Users should be able to trigger jobs manually, view job logs, and see success/failure statistics.

This feature is essential for operational transparency and troubleshooting, allowing users to understand what background tasks are running and when, similar to how cron monitoring works in enterprise applications.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 UI displays all configured Oban cron jobs with their schedules
- [x] #2 Shows next scheduled run time for each job in human-readable format
- [x] #3 Displays last run time and execution status (success/failure) for each job
- [x] #4 Job execution history is viewable with filtering by job type and status
- [x] #5 Users can manually trigger jobs with confirmation dialog
- [x] #6 Job details include execution time, error messages, and retry information
- [x] #7 Real-time updates show job status changes using LiveView
- [x] #8 Job statistics show success rate, average duration, and failure count
- [x] #9 Admin-only access control for job management features
- [x] #10 Links to relevant UI sections (e.g., library scanner → media library view)
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
## Implementation Plan

### Phase 1: Core LiveView Structure
- Create `MydiaWeb.JobsLive.Index` LiveView module
- Create corresponding HEEx template
- Add admin-only route in router

### Phase 2: Data Layer
- Create `Mydia.Jobs` context module for Oban data queries
- Implement functions: list_cron_jobs, list_job_history, get_job_stats, trigger_job
- Query Oban tables directly using Ecto

### Phase 3: Features Implementation
- Cron jobs display with schedule, last/next run times
- Job history with filtering (worker, state, date)
- Manual job triggering with confirmation modal
- Job details view modal
- Real-time updates via Oban.Notifier
- Statistics dashboard per job
- Navigation links to relevant UI sections
- Admin access control via existing pipeline

### Phase 4: Polish
- UI/UX enhancements (color-coded badges, relative timestamps)
- Error handling and validation

### Dependencies
- Add :crontab for schedule parsing

### Key Files
- lib/mydia/jobs.ex (new)
- lib/mydia_web/live/jobs_live/index.ex (new)
- lib/mydia_web/live/jobs_live/index.html.heex (new)
- lib/mydia_web/router.ex (modify)
- mix.exs (add dependency)
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Summary

Successfully implemented a comprehensive Oban background jobs monitoring and management UI.

### What was built:

1. **Context Layer** (`lib/mydia/jobs.ex`):
   - `list_cron_jobs/0` - Parses Oban config and returns cron job definitions with next run times
   - `list_job_history/1` - Queries oban_jobs table with filtering (worker, state, pagination)
   - `get_latest_job/1` - Fetches most recent execution for a worker
   - `get_job_stats/1` - Calculates success rate, average duration, failure count per worker
   - `trigger_job/1` - Manually enqueues a job via Oban.insert/1
   - `count_job_history/1` - Counts jobs for pagination

2. **LiveView** (`lib/mydia_web/live/jobs_live/index.ex`):
   - Displays all configured cron jobs with schedules, last/next run times, and stats
   - Shows job execution history with filtering and pagination
   - Real-time updates via telemetry attachment to [:oban, :job, :stop] events
   - Manual job triggering with confirmation modal
   - Job details modal showing args, errors, attempts, duration
   - Helper functions for formatting timestamps, durations, and state badges

3. **Template** (`lib/mydia_web/live/jobs_live/index.html.heex`):
   - Scheduled jobs table with job name, schedule, last/next run, status, stats, and actions
   - Job history table with filtering by worker and state
   - Load more pagination for history
   - Color-coded state badges (green=success, red=failed, yellow=retrying)
   - Relative timestamps with tooltips showing exact times
   - Two modals: job details and trigger confirmation
   - Navigation link to media library from LibraryScanner job

4. **Router Updates**:
   - Added admin-only route at `/admin/jobs`
   - Uses `:require_admin` pipeline for access control
   - New `:admin` live_session with UserAuth on_mount hook

5. **Navigation**:
   - Added "Background Jobs" link to sidebar under "Administration" section

### Technical Details:
- Uses `:crontab` library to parse cron expressions and calculate next run times
- Queries Oban's oban_jobs table directly using Ecto for job history
- Telemetry integration for real-time job completion updates
- DaisyUI components for polished UI (tables, badges, modals, cards)
- Admin-only access enforced via existing authentication pipeline

### Fixed Issues:
- Corrected `calculate_next_run/1` to unwrap `{:ok, datetime}` tuple from Crontab.Scheduler
- Applied code formatting to meet project standards
<!-- SECTION:NOTES:END -->
