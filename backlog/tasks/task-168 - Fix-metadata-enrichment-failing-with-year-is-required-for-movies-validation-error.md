---
id: task-168
title: >-
  Fix metadata enrichment failing with "year is required for movies" validation
  error
status: In Progress
assignee:
  - Claude
created_date: '2025-11-11 16:47'
updated_date: '2025-11-11 16:49'
labels:
  - bug
  - metadata-matching
  - validation
  - import
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Metadata enrichment is failing to create media items even when TMDB successfully returns complete metadata including the year. The changeset validation rejects the data with "year is required for movies" despite the year being present in the fetched metadata.

**Error message:**
```
Failed to enrich metadata: #Ecto.Changeset<
  action: :insert, 
  changes: %{
    type: "movie", 
    title: "Dune: Part Two",
    metadata: %{
      year: 2024,
      release_date: ~D[2024-02-27],
      ...
    },
    tmdb_id: 693134,
    ...
  }, 
  errors: [year: {"is required for movies", []}], 
  valid?: false
>
```

**Analysis:**
The metadata fetched from TMDB contains complete information including:
- `year: 2024` in the metadata map
- `release_date: ~D[2024-02-27]` 
- `tmdb_id: 693134`
- Full cast, crew, genres, etc.

However, the changeset validation fails because the `year` field is not being properly set on the media_item record itself, even though it exists in the nested metadata map.

**Root cause (suspected):**
The metadata enrichment process likely has one of these issues:
1. The `year` field is not being extracted from the metadata and set as a top-level field on the media_item
2. The validation runs before the year field is populated from the metadata
3. The field mapping between TMDB response and MediaItem schema is incorrect
4. The changeset is missing the year field in the `cast/3` call

**Expected behavior:**
When metadata is successfully fetched from TMDB with a year/release_date:
1. Extract the year from the metadata (either from `year` or `release_date`)
2. Set it as a top-level field on the MediaItem struct
3. Validation should pass
4. Media item should be created successfully

**Impact:**
- Users cannot import movies even when metadata is found
- Files remain orphaned in the database
- Import process appears to succeed (finds metadata) but silently fails at the database insertion step
- Users see vague "Failed to enrich" errors without understanding the issue

**Example scenario:**
1. User scans library, finds "Dune: Part Two" file
2. Metadata matcher successfully finds TMDB entry (ID: 693134)
3. Metadata enricher fetches complete metadata from TMDB
4. Changeset creation fails year validation
5. File remains orphaned, cannot be imported
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Year field is properly extracted from TMDB metadata
- [x] #2 Year is set as top-level field on MediaItem before validation
- [ ] #3 Changeset validation passes when year is present in metadata
- [ ] #4 Movies with valid release dates can be successfully imported
- [ ] #5 Error messages clearly indicate what field is missing and why
- [ ] #6 Tests cover year field extraction and validation
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Root Cause Found

The issue was in `lib/mydia/library/metadata_enricher.ex:165-182`. The `extract_year/1` function only handled date values as strings, but TMDB metadata can return `release_date` and `first_air_date` as Date structs.

When the function tried to call `String.slice/2` on a Date struct, it would fail and return `nil` (caught by rescue), causing the year field to be nil and triggering the validation error.

## Fix Applied

Refactored `extract_year/1` to delegate to a new helper function `extract_year_from_date/1` that handles both:
1. Date structs - directly access `.year` field
2. String dates - extract first 4 characters and convert to integer
3. Any other value - return nil

This ensures the year is properly extracted regardless of the date format returned by TMDB.
<!-- SECTION:NOTES:END -->
