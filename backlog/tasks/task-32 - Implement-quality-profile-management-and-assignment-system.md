---
id: task-32
title: Implement quality profile management and assignment system
status: To Do
assignee: []
created_date: '2025-11-04 16:01'
labels:
  - quality
  - settings
  - admin
  - liveview
dependencies:
  - task-9
  - task-15
  - task-25.4
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Build the quality profile management system that defines preferred qualities, file sizes, and upgrade rules for automatic downloads. Quality profiles are assigned to media items and used by automatic search to determine which releases to download.

The database schema for `quality_profiles` already exists (created in task-9), but there's no context module or UI for managing profiles. This task implements the full CRUD interface and profile application logic.

## Implementation Details

**Quality Profile Schema (Existing):**
```elixir
quality_profiles table:
  - id, name
  - min_size_mb, max_size_mb
  - preferred_quality (string: "1080p", "2160p", etc.)
  - allowed_qualities (list of allowed resolutions)
  - cutoff_quality (stop upgrading after reaching this)
  - upgrade_until_quality (upgrade releases until this quality)
  - preferred_tags (list: "PROPER", "REPACK", etc.)
  - blocked_tags (list: "CAM", "TS", etc.)
```

**Context Module: `Mydia.Settings.QualityProfiles`**
- Create/update/delete quality profiles
- List all profiles
- Get profile by ID
- Validate profile settings (min < max size, valid qualities)
- Check if a SearchResult matches a profile
- Score/rank SearchResults based on profile preferences

**Admin UI Integration:**
Add quality profiles tab to admin config page (task-15/25):
- List all quality profiles with summary
- Create/edit profile form with:
  - Name and description
  - Quality preferences (allowed, preferred, cutoff)
  - Size constraints (min/max MB)
  - Tag preferences and blacklist
  - Upgrade rules
- Delete profile (with confirmation if assigned to media)
- Duplicate profile for easier variant creation

**Profile Assignment:**
- Add `quality_profile_id` field to MediaItems (migration needed)
- Profile selector dropdown on media creation/edit
- Show assigned profile on media detail page
- Allow changing profile for existing media

**Profile Matching Logic:**
For a given SearchResult and QualityProfile, determine:
- Does it meet minimum requirements? (allowed quality, size range, no blocked tags)
- Is it preferred? (matches preferred quality, has preferred tags)
- Is it an upgrade? (better than current quality for that media item)
- Quality score (0-100) for ranking multiple matches

**Pre-defined Profiles:**
Create seed data with common profiles:
- "Any" - Any quality, no size limits
- "HD" - 720p/1080p, 1-10GB
- "Full HD" - 1080p only, 2-15GB  
- "4K" - 2160p, 15-80GB
- "SD" - 480p/DVD quality, under 2GB
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Quality profile context module with CRUD operations
- [ ] #2 Quality profile validation (sizes, qualities, rules)
- [ ] #3 Admin UI tab for managing quality profiles
- [ ] #4 Create/edit profile form with all settings
- [ ] #5 List view showing all profiles with summary
- [ ] #6 Delete profile with validation (check if assigned)
- [ ] #7 Duplicate profile functionality
- [ ] #8 Match/score SearchResult against profile logic
- [ ] #9 Profile assignment on media items (add quality_profile_id field)
- [ ] #10 Profile selector on media create/edit forms
- [ ] #11 Show assigned profile on media detail page
- [ ] #12 Seed data with common pre-defined profiles
- [ ] #13 Profile matching considers: allowed qualities, size range, tags, upgrade rules
<!-- AC:END -->
