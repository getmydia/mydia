---
id: task-42
title: Improve search results table layout by consolidating columns
status: Done
assignee: []
created_date: '2025-11-04 21:07'
updated_date: '2025-11-04 21:12'
labels:
  - ui
  - search
  - liveview
  - enhancement
dependencies:
  - task-22.8
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The /search page currently displays search results in a table with too many columns, causing the quality information to be cut off and making the interface cluttered. The table should be redesigned to merge related columns together for better readability and to ensure all information is visible without truncation.

The search results table should present all necessary information (title, quality, size, seeders/peers, indexer source, publish date) in a more compact and readable format that works well on different screen sizes.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Quality information is fully visible without being cut off
- [x] #2 Related columns are merged to reduce total column count
- [x] #3 Table layout remains readable and properly aligned
- [x] #4 All search result metadata (title, quality, size, seeders, indexer, date) is still accessible
- [x] #5 Layout works responsively on mobile and desktop viewports
- [x] #6 Visual hierarchy makes it easy to scan and compare results
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Successfully consolidated the search results table from 9 columns to 5 columns:

1. **Release Title** (40% width) - Main column with larger space for titles
2. **Quality & Size** (16.6% width) - Combined quality badge and file size in one column
3. **Health** (16.6% width, hidden on mobile) - Health score indicator with seeders/peers displayed together
4. **Source** (16.6% width, hidden on large screens and below) - Indexer and published date combined
5. **Actions** (fixed 128px width) - Download and add to library buttons

Mobile Layout:
- On mobile devices, only Title, Quality & Size, and Actions columns are visible
- Seeder/peer counts and indexer information are shown as compact badges below the title
- All information remains accessible without horizontal scrolling

The new layout ensures:
- Quality information is fully visible without truncation
- Related data is logically grouped together
- Better use of horizontal space
- Improved visual hierarchy for scanning results
- Responsive design that works on all screen sizes
<!-- SECTION:NOTES:END -->
