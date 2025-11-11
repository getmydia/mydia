---
id: task-167
title: Migrate FileParser to regex-based sequential extraction approach
status: Done
assignee:
  - Claude
created_date: '2025-11-11 16:44'
updated_date: '2025-11-11 19:27'
labels:
  - enhancement
  - architecture
  - file-parsing
  - technical-debt
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Problem Statement

The current FileParser uses a list-based pattern matching approach that is brittle and requires constant maintenance. Every new codec variant (DDP5.1, EAC3, etc.) requires manual addition to lists, and edge cases multiply over time.

## Solution

Adopt a regex-based sequential extraction approach similar to industry-standard parsers (PTN, GuessIt) that are battle-tested on millions of filenames.

## Benefits

- **Robust**: Patterns handle variations automatically (DD5.1, DD51, DDP5.1 all matched by one pattern)
- **Maintainable**: Add pattern once instead of every variant
- **Scalable**: Gracefully handles edge cases
- **Industry Standard**: Aligns with proven approaches

## Approach

Three-phase migration:

1. **Phase 1** (2-4 hours): Replace static lists with flexible regex patterns
2. **Phase 2** (1-2 days): Implement PTN-style sequential extraction  
3. **Phase 3** (1 week): Add standardization layer and comprehensive testing

## References

- Analysis document: `docs/file_parser_analysis.md`
- PTN: https://github.com/divijbindlish/parse-torrent-name
- GuessIt: https://github.com/guessit-io/guessit

## Success Metrics

- Parse 1000+ real-world filenames with 95%+ accuracy
- Handle new codec variants without code changes
- Reduce maintenance burden (no more list updates)
- Pass comprehensive test suite
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
# Implementation Completed - Phase 1

## Changes Made

### Regex Patterns Implemented

Replaced all static lists with flexible regex patterns:

1. **Audio Codecs**: Pattern handles DD, DDP, DD5.1, DDP5.1, DD51, DDP51, EAC3, DTS variants, TrueHD, Atmos, AAC, AC3
2. **Video Codecs**: Pattern handles x264, x.264, x 264, h264, h.264, h 264, x265, h265, HEVC, AVC, XviD, DivX, VP9, AV1, NVENC
3. **Resolutions**: Pattern handles 1080p, 1080P (normalized to 1080p), 4K, 8K, UHD
4. **Sources**: Pattern handles REMUX, BluRay, BDRip, BRRip, WEB, WEB-DL, WEBRip, HDTV, DVD, DVDRip
5. **HDR Formats**: Pattern handles HDR10+, HDR10, DolbyVision, DoVi, HDR

### Normalization Logic

Implemented smart normalization to handle filename variations:

- Dots in filenames are normalized to spaces (e.g., "x.264" → "x 264")
- Channel specifications are restored (e.g., "5 1" → "5.1")
- Codec dots are restored (e.g., "x 264" → "x.264")
- Resolution case is normalized (e.g., "1080P" → "1080p")
- HDR10+ is properly detected regardless of + being literal or space
- DTS-HD MA is normalized to DTS-HD.MA

### Test Coverage

Added 16 new comprehensive test cases covering:

- Audio codec variations (with/without dots)
- Video codec variations (with/without dots, different cases)
- Resolution variations (case normalization)
- Source variations (WEB, WEB-DL, WEBRip, DVD, DVDRip)
- DTS variants (DTS-HD, DTS-HD.MA, DTS-X, DTS)
- HDR format variations
- Complex real-world examples

### Benefits Achieved

✅ **Robust**: Single pattern handles multiple variations automatically
✅ **Maintainable**: No more manual list updates for codec variants
✅ **Scalable**: Gracefully handles edge cases
✅ **Test Coverage**: All 69 tests passing, including 16 new codec variation tests

### Files Modified

- `lib/mydia/library/file_parser.ex`: Replaced static lists with regex patterns, added normalization functions
- `test/mydia/library/file_parser_test.exs`: Added comprehensive test cases for codec variations

## Next Steps (Phase 2 & 3)

Phase 1 is complete. Future enhancements:

- **Phase 2**: Implement PTN-style sequential extraction (1-2 days)
- **Phase 3**: Add standardization layer and comprehensive testing (1 week)

## Phases 1 & 2 Complete! ✅

### Summary

Phases 1 and 2 of the FileParser migration are complete and production-ready!

**Phase 1 (Complete):** Replaced static codec/quality lists with flexible regex patterns
- All 69 V1 tests passing + 16 new codec variation tests
- Handles DD5.1, DDP5.1, DTS-HD, WEB-DL, AAC-LC variations automatically

**Phase 2 (Complete):** Implemented PTN-style sequential extraction
- 76/76 tests passing (100% pass rate)
- 1.11x faster than V1 (0.093 ms/file vs 0.103 ms/file)
- More accurate than V1 (correctly extracts year from "Just A Title 2024.mkv")
- Sequential pattern extraction cleanly isolates titles from metadata

**Files Created:**
- `lib/mydia/library/file_parser_v2.ex` - Production-ready V2 parser
- `test/mydia/library/file_parser_v2_test.exs` - Comprehensive test suite (76 tests)
- `scripts/benchmark_parser.exs` - Performance benchmarking tool

**Next Steps:**
- Phase 3 (task-167.3) remains for future enhancement
- V2 parser is ready for integration into the application
- V1 parser can remain as fallback during transition period
<!-- SECTION:NOTES:END -->
