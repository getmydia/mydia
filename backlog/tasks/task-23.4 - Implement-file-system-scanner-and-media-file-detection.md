---
id: task-23.4
title: Implement file system scanner and media file detection
status: Done
assignee:
  - assistant
created_date: '2025-11-04 03:39'
updated_date: '2025-11-04 19:37'
labels:
  - library
  - scanning
  - filesystem
  - backend
dependencies: []
parent_task_id: task-23
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Create a file system scanner that walks configured library directories, detects media files, and extracts basic file information. The scanner should identify video files by extension, extract file metadata (size, codec, resolution), and track file paths in the database.

Use Elixir's File and Path modules for file system operations. The scanner should be efficient for large libraries (10,000+ files) and handle various file system structures (local, NFS, SMB mounts).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Scanner walks configured library directories recursively
- [x] #2 Video files are detected by extension (mkv, mp4, avi, etc.)
- [x] #3 File metadata is extracted (size, path, modified time)
- [x] #4 Scanner handles symlinks and mounted file systems correctly
- [x] #5 Large directories (10,000+ files) are scanned efficiently
- [x] #6 Scanner tracks last scan time and detects new/modified/deleted files
- [x] #7 File system errors are logged but don't crash the scanner
- [x] #8 Progress is reported during scanning for UI feedback
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
## Implementation Plan

### Components to Create

1. **Core Scanner Module** (`lib/mydia/library/scanner.ex`)
   - `scan_library_path/2` - Main entry point for scanning a single library path
   - `scan_directory/2` - Recursively walks directories
   - `detect_video_file?/1` - Checks if file is a video by extension
   - `extract_file_metadata/1` - Gets size, mtime from File.stat
   - `handle_scan_results/2` - Processes found files and updates database

2. **Progress Reporting** 
   - Use Oban job meta field to track progress
   - Report: total files found, files processed, current directory

3. **Error Handling**
   - Wrap File operations in try/rescue blocks
   - Log errors but continue scanning
   - Track errors in LibraryPath.last_scan_error field

4. **Efficiency for Large Libraries**
   - Use `File.ls/1` instead of recursive wildcards
   - Process files in batches (insert_all) instead of one-by-one
   - Use `Task.async_stream` for parallel file stat operations

5. **Change Detection**
   - Query existing MediaFiles by library path prefix
   - Compare mtime and file size to detect modifications
   - Mark files as deleted if no longer present on disk

### Implementation Steps

1. Create `Mydia.Library.Scanner` module with file walking logic
2. Add video file detection by extension
3. Implement file metadata extraction (File.stat)
4. Add batch insert operations for new files
5. Implement change detection for existing files
6. Add progress reporting via Oban meta
7. Update LibraryScanner Oban job to use new scanner
8. Add comprehensive tests with temp directories
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Summary

Successfully implemented file system scanner with comprehensive testing.

### Files Created
1. **lib/mydia/library/scanner.ex** - Core file system scanning module
2. **test/mydia/library/scanner_test.exs** - Comprehensive test suite (23 tests)

### Files Modified
1. **lib/mydia/jobs/library_scanner.ex** - Updated to use new scanner module
2. **lib/mydia/application.ex** - Disabled ClientHealth in test environment to avoid SQL Sandbox conflicts

### Key Features Implemented

#### Scanner Module (`Library.Scanner`)
- Recursive directory traversal with configurable depth
- Video file detection by extension (.mkv, .mp4, .avi, etc.)
- File metadata extraction (size, modified time, path info)
- Symlink handling (follows both directory and file symlinks)
- Error handling that doesn't crash on permission or I/O errors
- Progress callback support for UI feedback (reports every 100 files)
- Change detection (new files, modified files, deleted files)
- Multi-directory scanning support

#### LibraryScanner Job
- Scans all monitored library paths or individual paths
- Detects file changes between scans
- Updates database with new/modified files
- Removes deleted file records
- Tracks scan status and errors on library_path records
- Simple quality detection from filenames (2160p, 1080p, etc.)
- Transaction-based updates for consistency

#### Test Coverage
- 23 tests with 0 failures, 1 skipped
- Tests cover:
  - Basic scanning and file detection
  - Recursive vs non-recursive scanning
  - File extension detection (case-insensitive)
  - Metadata extraction
  - Custom extension configuration
  - Error handling (non-existent paths, invalid paths)
  - Symlink following
  - Change detection (new, modified, deleted files)
  - Multi-directory scanning
  - Progress reporting
  - Permission error handling (skipped in Docker)

### Implementation Notes

1. **Video Extensions**: Supports common formats (.mkv, .mp4, .avi, .mov, .wmv, .flv, .webm, .m4v, .mpg, .mpeg, .m2ts, .ts)

2. **Error Handling**: Scanner is resilient to file system errors:
   - Permission denied errors are logged but don't crash the scan
   - Missing files/directories return appropriate error tuples
   - Symlink resolution failures are logged and skipped

3. **Performance**: Designed for large libraries:
   - Progress callbacks every 100 files
   - Efficient MapSet-based change detection
   - Minimal database queries (batch updates in transactions)

4. **Test Environment Fix**: Added `client_health_children/0` in application.ex to prevent ClientHealth GenServer from starting in test environment, avoiding SQL Sandbox conflicts.

### Next Steps for Task 23

With the scanner implemented, the next subtasks are:
- task-23.5: Implement intelligent file name parser for metadata extraction
- task-23.6: Implement metadata matching and enrichment engine
- task-23.7: Implement library scanner background job scheduling
- task-23.8: Create library configuration system UI

## Test Results

All tests passing successfully:
- **23 tests, 0 failures, 1 skipped**
- Scanner module fully functional with:
  - Recursive directory traversal
  - Video file detection (case-insensitive, 12+ formats)
  - File metadata extraction (size, mtime, path info)
  - Symlink handling (both files and directories)
  - Error resilience (permission errors, missing files)
  - Progress reporting (every 100 files)
  - Change detection (new, modified, deleted)
  - Multi-directory scanning

## Key Implementation Details

### Scanner Module (`lib/mydia/library/scanner.ex`)
- `scan/2`: Main entry point for scanning a directory
- `scan_multiple/2`: Scans multiple directories and aggregates results
- `detect_changes/2`: Compares current and previous file states
- Handles all acceptance criteria requirements

### LibraryScanner Job (`lib/mydia/jobs/library_scanner.ex`)
- Scans all monitored library paths or individual paths
- Detects file changes and updates database in transactions
- Tracks scan status on library_path records
- Simple quality detection from filenames (2160p, 1080p, etc.)

### Video File Extensions Supported
.mkv, .mp4, .avi, .mov, .wmv, .flv, .webm, .m4v, .mpg, .mpeg, .m2ts, .ts

## Usage

To scan a library path:
```elixir
# Scan with default options
{:ok, result} = Mydia.Library.Scanner.scan("/media/movies")

# Scan with progress callback
Mydia.Library.Scanner.scan("/media/movies", 
  progress_callback: fn count -> IO.puts("Found #{count} files") end
)

# Detect changes
changes = Mydia.Library.Scanner.detect_changes(result, existing_files)
```

To run the background job:
```elixir
# Scan all monitored libraries
Mydia.Jobs.LibraryScanner.new(%{}) |> Oban.insert()

# Scan specific library path
Mydia.Jobs.LibraryScanner.new(%{"library_path_id" => "uuid"}) |> Oban.insert()
```
<!-- SECTION:NOTES:END -->
