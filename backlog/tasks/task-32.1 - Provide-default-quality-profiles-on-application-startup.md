---
id: task-32.1
title: Provide default quality profiles on application startup
status: Done
assignee: []
created_date: '2025-11-04 20:27'
updated_date: '2025-11-04 20:34'
labels:
  - quality
  - defaults
  - initialization
  - settings
dependencies:
  - task-32
parent_task_id: task-32
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Ensure the application always has a set of default quality profiles available, even in a fresh installation or when the database is reset. These profiles should be created automatically on application startup if they don't exist, providing users with sensible defaults they can use immediately or customize.

## Context

Task-32 covers the quality profile management system and includes seed data. However, seed data is typically only run once during initial setup with `mix ecto.setup`. This task ensures default profiles are always available, even if seeds weren't run or the database was migrated without seeding.

## Implementation Approach

**Option 1: Migration-based defaults**
- Create a migration that inserts default profiles
- Ensures profiles exist after `mix ecto.migrate`
- Profiles are part of the schema, not optional seed data

**Option 2: Application startup initialization**
- Add initialization logic in `Mydia.Application.start/2`
- Check if default profiles exist on startup
- Create them if missing (idempotent operation)

**Option 3: First-access initialization**
- Check for default profiles when `Mydia.Settings.list_quality_profiles/0` is first called
- Create defaults if none exist
- Lazy initialization approach

## Default Profiles to Provide

Common profiles that cover most use cases:
- **"Any"** - Any quality, no size limits (for maximum availability)
- **"SD"** - 480p/DVD quality, under 2GB (for limited storage)
- **"HD-720p"** - 720p, 1-5GB (balanced quality/size)
- **"HD-1080p"** - 1080p, 2-15GB (standard high quality)
- **"Full HD"** - 1080p only, 4-20GB (strict quality control)
- **"4K/UHD"** - 2160p, 15-80GB (maximum quality)

## Considerations

- Should default profiles be marked as system-provided (read-only or special handling)?
- Should they be recreated if deleted by user?
- How to handle upgrades when default profile definitions change?
- Should users be able to restore default profiles if they modify/delete them?
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Default quality profiles are automatically created if they don't exist
- [x] #2 Profiles include: Any, SD, HD-720p, HD-1080p, Full HD, 4K/UHD
- [x] #3 Initialization is idempotent (safe to run multiple times)
- [x] #4 Each profile has sensible defaults for size limits, allowed qualities, and tags
- [x] #5 Profiles are available immediately after fresh database setup
- [x] #6 Documentation explains how defaults are provided and when they're created
- [x] #7 Tests verify default profiles are created correctly
- [ ] #8 Consider marking defaults as system-provided (optional enhancement)
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Summary

Successfully implemented default quality profile initialization on application startup.

### Changes Made

1. **Created `Mydia.Settings.DefaultQualityProfiles` module** (`lib/mydia/settings/default_quality_profiles.ex`)
   - Defines 6 default quality profiles: Any, SD, HD-720p, HD-1080p, Full HD, 4K/UHD
   - Each profile includes qualities (resolutions), upgrade settings, and rules (size limits, preferred sources)
   - Profiles range from "Any" (maximizes availability) to "4K/UHD" (maximum quality)

2. **Added `ensure_default_quality_profiles/0` function to Settings context** (`lib/mydia/settings.ex`)
   - Idempotent function that creates missing default profiles
   - Returns `{:ok, created_count}` on success
   - Handles database unavailability gracefully (returns `{:error, :database_unavailable}`)
   - Uses efficient querying to check existing profiles by name

3. **Integrated into Application startup** (`lib/mydia/application.ex`)
   - Added `ensure_default_quality_profiles/0` private function
   - Called after supervisor starts and adapters are registered
   - Provides user feedback when profiles are created ("✓ Created N default quality profile(s)")
   - Silently succeeds if profiles already exist or database is not ready

4. **Comprehensive test coverage** (`test/mydia/settings_test.exs`)
   - Tests idempotency (can be called multiple times safely)
   - Tests partial creation (only creates missing profiles)
   - Tests profile structure and required fields
   - Tests size constraints and upgrade settings
   - Tests profile definition uniqueness and validity
   - All 9 tests pass successfully

### Default Profile Specifications

- **Any**: All qualities (360p-2160p), allows upgrades, no size limits
- **SD**: 480p/576p, upgrades to 576p, max 2GB, prefers DVD sources
- **HD-720p**: 720p only, 1-5GB, no upgrades, prefers BluRay/WEB-DL/HDTV
- **HD-1080p**: 1080p only, 2-15GB, no upgrades, prefers BluRay/WEB-DL
- **Full HD**: 1080p only, 4-20GB, no upgrades, prefers BluRay
- **4K/UHD**: 2160p only, 15-80GB, no upgrades, prefers BluRay/WEB-DL

### Verification

Confirmed profiles are created on application startup:
- Application starts successfully
- All 6 profiles created: "4K/UHD", "Any", "Full HD", "HD-1080p", "HD-720p", "SD"
- Initialization is idempotent (returns 0 created on subsequent calls)
- All tests pass (9/9)
<!-- SECTION:NOTES:END -->
