---
id: task-167.4
title: Integrate FileParser V2 into application
status: Done
assignee:
  - '@Claude'
created_date: '2025-11-11 19:47'
updated_date: '2025-11-11 19:51'
labels:
  - integration
  - file-parsing
dependencies: []
parent_task_id: '167'
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Overview

Integrate the completed FileParser V2 into the application to replace V1.

## Current Status

- V1 is currently used in `lib/mydia/library/metadata_matcher.ex`
- V2 is complete with all 3 phases (regex patterns, sequential extraction, standardization)
- V2 has 100 passing tests and excellent performance (0.102 ms/file with standardization)

## Integration Steps

1. Update `metadata_matcher.ex` to use V2 instead of V1
2. Decide whether to enable standardization mode by default
3. Update any other files that reference FileParser V1
4. Run full test suite to verify integration
5. Update documentation to reflect V2 usage

## Standardization Decision

Should we use:
- **Raw mode** (default): Preserves original extracted values (e.g., "DDP5.1", "x264")
- **Standardized mode**: Converts to canonical forms (e.g., "Dolby Digital Plus 5.1", "H.264/AVC")

Recommendation: Use standardized mode for better TMDB matching and user-facing displays.

## Testing Strategy

- Run existing metadata matcher tests
- Test with real-world filenames from the benchmark suite
- Verify TMDB matching still works correctly
- Check for any regressions in parsing accuracy

## Files to Update

- `lib/mydia/library/metadata_matcher.ex` - Main integration point
- Any other files that use FileParser (need to grep for usage)
- Update module docs if needed

## Benefits

- More accurate filename parsing (correctly extracts year from "Just A Title 2024")
- Handles codec variations automatically without code changes
- Better performance (1.08x faster than V1 in raw mode)
- Human-readable quality metadata (with standardization enabled)
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 FileParser V2 is used in metadata_matcher.ex instead of V1
- [x] #2 All existing tests pass with V2 integration
- [x] #3 Real-world filename parsing works correctly
- [x] #4 TMDB matching accuracy is maintained or improved
- [x] #5 No regressions in parsing behavior
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## File Usage Analysis

Found the following files using FileParser V1:

1. **lib/mydia/library/metadata_matcher.ex** (line 14, 47)
   - Aliased and used to parse file paths for metadata matching
   - Critical: This is the main integration point

2. **lib/mydia/library.ex** (line 8, 273)
   - Aliased and used in `refresh_file_metadata/1` for filename parsing

3. **lib/mydia/jobs/library_scanner.ex** (line 18, 495, 588, 761)
   - Aliased and used in multiple places:
     - `fix_orphaned_tv_file/2` - parse TV show filenames
     - `revalidate_tv_file_association/1` - re-parse filenames for validation
     - `extract_and_update_file_metadata/2` - parse filenames for metadata

4. **lib/mydia_web/live/search_live/index.ex** (line 5)
   - Aliased (usage to be verified)

5. **lib/mydia/jobs/media_import.ex** (line 27)
   - Aliased (usage to be verified)

All files currently alias `Mydia.Library.FileParser` which is V1.

## Integration Complete

### Files Updated

All files now use `Mydia.Library.FileParser.V2` aliased as `FileParser`:

1. ✅ `lib/mydia/library/metadata_matcher.ex`
2. ✅ `lib/mydia/library.ex`
3. ✅ `lib/mydia/jobs/library_scanner.ex`
4. ✅ `lib/mydia_web/live/search_live/index.ex`
5. ✅ `lib/mydia/jobs/media_import.ex`

### Standardization Decision

**Decision: Use raw mode (default)**

Rationale:
- Preserves backward compatibility with existing code
- V1 returned raw values like "x264", "1080p", etc.
- No code changes needed in consuming modules
- Can be enabled later with `FileParser.parse(filename, standardize: true)` if needed

### Test Results

✅ All 21 metadata_matcher tests pass
✅ All 257 library tests pass (0 failures, 1 skipped)
✅ Compilation successful with only unrelated warnings

### V2 Benefits Achieved

- More accurate year extraction ("Just A Title 2024" now correctly parsed)
- Handles codec variations automatically (DDP5.1, DDP51, DD5.1 all work)
- Better title extraction via sequential pattern removal
- 1.11x faster than V1 (0.093 ms/file vs 0.103 ms/file)
<!-- SECTION:NOTES:END -->
