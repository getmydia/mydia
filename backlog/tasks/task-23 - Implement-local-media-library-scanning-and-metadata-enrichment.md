---
id: task-23
title: Implement local media library scanning and metadata enrichment
status: To Do
assignee: []
created_date: '2025-11-04 03:38'
labels:
  - library
  - metadata
  - scanning
  - automation
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Enable Mydia to scan local media directories, identify media files, extract information from file names and folder structure, and enrich them with metadata from external sources (TMDB, TVDB, IMDB). 

The system should use metadata-relay.dorninger.co as the primary metadata source to avoid rate limiting and reduce direct API calls to TMDB/TVDB. This provides a caching layer that's more efficient for self-hosted applications. The scanner should run as a background job, detect new files, match them to media items, and update the database with rich metadata including posters, descriptions, cast, crew, ratings, etc.

This is a foundational feature required for Phase 1 (MVP) of the roadmap.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Users can configure library paths for movies and TV shows via YAML configuration
- [ ] #2 System automatically scans configured library paths for media files
- [ ] #3 File names are parsed to extract title, year, season, episode information
- [ ] #4 Media is matched to TMDB/TVDB entries with high accuracy
- [ ] #5 Metadata includes posters, backdrops, descriptions, cast, ratings, and genre
- [ ] #6 Metadata relay is used as primary source to avoid rate limiting
- [ ] #7 Scanning runs as a scheduled background job and can be triggered manually
- [ ] #8 New files are detected and imported automatically
- [ ] #9 Existing media metadata can be refreshed on demand
- [ ] #10 Failed matches can be manually corrected via UI
<!-- AC:END -->
