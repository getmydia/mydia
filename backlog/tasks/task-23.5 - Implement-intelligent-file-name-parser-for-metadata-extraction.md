---
id: task-23.5
title: Implement intelligent file name parser for metadata extraction
status: Done
assignee: []
created_date: '2025-11-04 03:39'
updated_date: '2025-11-04 21:09'
labels:
  - library
  - parsing
  - backend
dependencies: []
parent_task_id: task-23
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Create a robust file name parser that extracts structured metadata from media file names and folder structures. The parser should handle common naming conventions used by the community (Scene releases, P2P groups, personal collections).

Support patterns like: 'Movie Title (2020) [1080p]', 'Show.Name.S01E05.720p.WEB', 'Movie.Title.2020.2160p.BluRay.x265-GROUP', etc. Extract title, year, season, episode, quality, release group, and other metadata from file names.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Parser extracts movie title and year from common naming patterns
- [x] #2 Parser extracts TV show name, season, and episode numbers
- [x] #3 Quality information (resolution, codec, HDR) is extracted from release names
- [x] #4 Release group names are identified and extracted
- [ ] #5 Folder structure is used to supplement file name parsing
- [x] #6 Parser handles edge cases (multiple episodes, special episodes, movies with years in title)
- [x] #7 Parsing confidence score is calculated for matching accuracy
- [x] #8 Unit tests cover 50+ real-world file naming patterns
<!-- AC:END -->
