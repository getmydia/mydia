---
id: task-33
title: Implement media item monitoring controls and actions
status: To Do
assignee: []
created_date: '2025-11-04 16:02'
labels:
  - library
  - liveview
  - ui
  - media
dependencies:
  - task-13
  - task-22.9
  - task-23.6
  - task-32
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add user controls and actions to the media detail view for managing monitored media items. This includes toggling monitoring status, triggering manual searches, refreshing metadata, changing quality profiles, and viewing history.

These controls give users fine-grained management over how their library items are tracked and acquired.

## Implementation Details

**UI Location:**
Media detail page (task-13) header/actions section

**Monitoring Controls:**

1. **Monitor Toggle**
   - Prominent toggle switch or button
   - Shows current monitoring status
   - Click to enable/disable monitoring
   - When enabled, item is included in automatic searches
   - When disabled, automatic searches skip this item
   - Confirmation modal if disabling has active downloads

2. **Search Button**
   - Triggers manual search (task-22.9)
   - Opens search results modal/section
   - Shows loading state during search
   - Badge showing last search time

3. **Refresh Metadata Button**
   - Re-fetches metadata from TMDB/TVDB
   - Updates title, year, poster, overview, episodes list
   - Shows last updated timestamp
   - Useful when metadata providers update their data

4. **Quality Profile Selector**
   - Dropdown to change assigned quality profile
   - Shows currently assigned profile (or "None")
   - Immediate update on selection
   - Shows profile details on hover

5. **Delete/Remove Button**
   - Removes media item from library
   - Confirmation modal with options:
     - Delete media record only
     - Delete media record and associated files
     - Delete media record, files, and downloads
   - Restricted by user permissions

**Additional Actions:**

6. **Edit Media Button**
   - Opens edit modal or page
   - Edit title, year, overview
   - Change media type
   - Adjust paths

7. **View Files Button**
   - Shows all associated media files
   - File quality, size, path
   - Actions: play, delete, re-import

8. **Download History**
   - List of all downloads for this media
   - Status, date, quality, source indexer
   - Click to view download details

**Status Indicators:**
- Monitoring status badge (Monitored/Unmonitored)
- File status (Missing/Available/Upgrading)
- Last search timestamp
- Next automatic search (if monitored)
- Current quality vs target quality

**For TV Shows:**
- Series-level monitoring toggle
- Per-season monitoring toggles
- Per-episode monitoring toggles
- Bulk actions for seasons/episodes

**LiveView Integration:**
- Real-time updates when background jobs run
- PubSub notifications for status changes
- Optimistic UI updates for instant feedback

**Permissions:**
- Regular users: toggle monitoring, trigger search, refresh metadata
- Admin users: delete, edit paths, manage files
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Monitor toggle switch on media detail page
- [ ] #2 Toggle updates monitored status in database
- [ ] #3 Manual search button triggers search modal (task-22.9)
- [ ] #4 Refresh metadata button re-fetches from provider
- [ ] #5 Quality profile selector dropdown with current profile
- [ ] #6 Delete button with confirmation and file deletion options
- [ ] #7 Edit media button/modal for updating metadata
- [ ] #8 View files section showing all media files
- [ ] #9 Download history list with status and details
- [ ] #10 Status indicators: monitoring, file availability, last search
- [ ] #11 For TV: series/season/episode-level monitoring controls
- [ ] #12 Real-time updates via PubSub when status changes
- [ ] #13 Permission checks for destructive actions
- [ ] #14 Last search and next search timestamps displayed
<!-- AC:END -->
