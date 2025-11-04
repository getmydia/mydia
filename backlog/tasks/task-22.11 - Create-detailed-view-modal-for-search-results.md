---
id: task-22.11
title: Create detailed view modal for search results
status: To Do
assignee: []
created_date: '2025-11-04 16:03'
labels:
  - search
  - ui
  - liveview
  - modal
dependencies:
  - task-22.8
  - task-29
  - task-31
parent_task_id: '22'
priority: low
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement a detailed view for individual search results that shows complete metadata, quality breakdown, and additional information before the user decides to download or add to library.

This provides transparency and helps users make informed decisions when selecting releases, especially when comparing similar torrents.

## Implementation Details

**UI Pattern:**
Modal dialog that opens when clicking on a search result row (not on action buttons)

**Detail View Content:**

1. **Header Section**
   - Full release title (not truncated)
   - Copy button for title
   - Indexer badge with link to info_url (if available)
   - Published date

2. **Quality Information**
   - Resolution (720p, 1080p, 2160p, etc.)
   - Source (BluRay, WEB-DL, HDTV, etc.)
   - Video codec (x264, x265, H.264, etc.)
   - Audio codec (AAC, AC3, DTS, etc.)
   - HDR status
   - Special flags (PROPER, REPACK, etc.)
   - Quality score (calculated)

3. **File Information**
   - Total file size (formatted)
   - Size appropriateness indicator (too small/large for quality)
   - Number of files (if available from indexer)
   - File list (if indexer provides it)

4. **Availability**
   - Seeders with icon
   - Leechers with icon
   - Health score with visualization
   - Age since publish
   - Estimated download time (if user has configured connection speed)

5. **Compatibility**
   - If quality profile assigned: match status
   - If searching for existing media: upgrade indicator
   - Size constraints check
   - Tag compatibility (preferred/blocked)

6. **Similar Releases**
   - Show other results from same search with similar titles
   - Quick comparison table
   - Highlight differences

7. **Actions**
   - Download button (task-29)
   - Add to library button (task-31)
   - Copy magnet link button
   - Report/flag button (future)

**Quality Profile Integration:**
- If viewing from library search (task-22.9) with quality profile
- Show compatibility details
- Highlight why it matches/doesn't match profile
- Show scoring breakdown

**Mobile Optimization:**
- Swipe up from bottom sheet on mobile
- Scrollable content
- Tap outside to close
- Responsive layout

**Keyboard Navigation:**
- Arrow keys to navigate between results
- ESC to close modal
- Enter to download selected result

**Performance:**
- Lazy load similar releases
- Cache parsed quality information
- Optimize for quick opening/closing
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Click search result row opens detail modal
- [ ] #2 Modal shows full release title and metadata
- [ ] #3 Quality breakdown with all parsed attributes
- [ ] #4 File information including size and file count
- [ ] #5 Seeder/leecher stats with health visualization
- [ ] #6 Quality profile compatibility details (if applicable)
- [ ] #7 Similar releases comparison section
- [ ] #8 Download and add to library actions work from modal
- [ ] #9 Copy magnet link functionality
- [ ] #10 Mobile-optimized bottom sheet presentation
- [ ] #11 Keyboard navigation (arrows, ESC, Enter)
- [ ] #12 Close modal by clicking outside or ESC key
<!-- AC:END -->
