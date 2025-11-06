---
id: task-113
title: Remove or hide frequent job execution events from activity feed
status: Done
assignee: []
created_date: '2025-11-06 21:25'
updated_date: '2025-11-06 21:31'
labels:
  - enhancement
  - ui
  - events
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The activity feed is being polluted by "Job executed: download_monitor" events that run every few minutes. Since we already have a dedicated Background Jobs page for monitoring job execution, these frequent job events should either be removed from the Events system or hidden by default in the activity feed.

## Problem
- download_monitor job runs every few minutes
- Creates excessive noise in the activity feed
- Makes it hard to see meaningful user activity and system events
- Background Jobs page already provides job monitoring

## Possible Solutions
1. Don't track job execution events at all (remove from Events system)
2. Add event filtering/categories in activity feed to hide job events by default
3. Only track job failures/errors, not successful executions
4. Add a separate "System Events" vs "User Activity" view

## Affected Areas
- lib/mydia/events.ex (event tracking)
- lib/mydia/jobs/download_monitor.ex (and other jobs)
- lib/mydia_web/live/activity_live/index.ex (activity feed filtering)
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Summary

Removed all job execution event tracking from the Events system. Job executions are already tracked on the Background Jobs page, so duplicate tracking in the activity feed was creating noise.

## Changes Made

1. **Removed job event tracking from all job files:**
   - `lib/mydia/jobs/download_monitor.ex` - Removed `Events.job_executed/2` call
   - `lib/mydia/jobs/library_scanner.ex` - Removed `Events.job_executed/2` and `Events.job_failed/3` calls
   - `lib/mydia/jobs/metadata_refresh.ex` - Removed multiple `Events.job_executed/2` and `Events.job_failed/3` calls
   - `lib/mydia/jobs/movie_search.ex` - Removed multiple `Events.job_executed/2` and `Events.job_failed/3` calls
   - `lib/mydia/jobs/tv_show_search.ex` - Removed multiple `Events.job_executed/2` and `Events.job_failed/3` calls

2. **Replaced with Logger statements:**
   - All job completion/failure tracking now uses `Logger.info/2` and `Logger.error/2`
   - Logger statements include duration, counts, and other relevant metrics
   - Logs are still available for debugging but don't pollute the activity feed

3. **Cleaned up unused imports:**
   - Removed unused `Events` alias from all modified job files

## Result

- Activity feed no longer shows frequent "Job executed: download_monitor" events
- Job execution information is still available on the Background Jobs page
- Application logs still contain detailed job execution information for debugging
- Code compiles successfully with no new warnings or errors
<!-- SECTION:NOTES:END -->
