# Investigation: Media File Relative Path Storage

**Date**: 2025-11-14
**Status**: ✅ Implemented (2025-11-15)
**Priority**: High
**Complexity**: High

---

**Implementation Summary**:
This investigation led to the successful implementation of relative path storage for media files (Task 207). All phases were completed including schema changes, data migration, code updates, testing, validation, documentation, and automatic database backups. See CHANGELOG.md and commit aa41161 for details.

## Problem Statement

Media files currently store absolute paths (e.g., `/mnt/media/Movies/The Matrix (1999)/movie.mkv`). This creates a critical issue: when a library path is updated in the configuration, all existing media file records become invalid because they still reference the old absolute path.

### Current Behavior

```elixir
# Before: Library path configured as /mnt/media/Movies
media_file.path = "/mnt/media/Movies/The Matrix (1999)/movie.mkv"

# After: User changes library path to /new/storage/Movies
# Library path updated ✓
# Media file path: Still "/mnt/media/Movies/..." ✗
# Result: File not found, playback fails
```

### Impact

1. **Broken file references** - All media files point to non-existent paths
2. **Playback failures** - Streaming fails because files can't be found
3. **No recovery path** - Changing back to old path doesn't help already-imported files
4. **Poor user experience** - Users can't relocate their media without losing the library

## Proposed Solution

Store media file paths as **relative paths** with a reference to the library path root. When a library path is updated, all associated files automatically resolve to the new location.

### New Behavior

```elixir
# Media file stores relative path + library path reference
media_file.relative_path = "The Matrix (1999)/The Matrix (1999) - 1080p.mkv"
media_file.library_path_id = "abc-123"

# Library path can be changed at any time
# Resolution: join(library_path.path, media_file.relative_path)
```

## System Architecture Analysis

### Current Configuration System

The application uses a **layered configuration approach**:

1. **Schema Defaults** (`lib/mydia/config/schema.ex`)
2. **YAML File** (`config/config.yml`)
3. **Database/UI Settings** (runtime configuration)
4. **Environment Variables** (highest priority)

Library paths support:
- Environment variables: `LIBRARY_PATH_1_PATH`, `LIBRARY_PATH_1_TYPE`, etc.
- Database storage in `library_paths` table
- Runtime merging via `Mydia.Config.Loader`

### Current Data Model

**Library Paths** (`lib/mydia/settings/library_path.ex`):
```elixir
schema "library_paths" do
  field :path, :string          # Absolute path to library root
  field :type, Ecto.Enum        # :movies, :series, :mixed
  field :monitored, :boolean
  field :scan_interval, :integer
  # ...
end
```

**Media Files** (`lib/mydia/library/media_file.ex`):
```elixir
schema "media_files" do
  field :path, :string                                    # Currently absolute
  belongs_to :media_item, Mydia.Media.MediaItem
  belongs_to :episode, Mydia.Media.Episode
  belongs_to :quality_profile, Mydia.Settings.QualityProfile
  # NO reference to library_path currently
end
```

### Key Code Locations

**File Import** (`lib/mydia/jobs/media_import.ex:499-500`):
- Builds absolute path: `dest_path = Path.join(dest_dir, final_filename)`
- Stores directly: `attrs = %{path: path, ...}`

**File Access** (`lib/mydia_web/controllers/api/stream_controller.ex:93,216`):
- Directly uses absolute path: `File.exists?(media_file.path)`
- Streams from: `file_path = media_file.path`

**Library Scanning** (`lib/mydia/library.ex:315-316,423-424,533-534`):
- Queries files by absolute path
- Compares existing paths as strings

**File Lookup** (`lib/mydia/library.ex:45-50`):
- Query: `where([f], f.path == ^path)`

## Migration Strategy

### Phase 1: Schema Changes

#### 1.1 Add Foreign Key to Library Path

**Rationale**: Media files must reference which library path they belong to for path resolution.

```elixir
# Migration: Add library_path_id to media_files
alter table(:media_files) do
  add :library_path_id, references(:library_paths, type: :string, on_delete: :cascade)
end

create index(:media_files, [:library_path_id])
```

**On Delete Behavior**: Use `CASCADE` - if a library path is deleted, remove associated files (they're now invalid).

#### 1.2 Add Relative Path Column

**Rationale**: Store path relative to library root. Keep absolute path temporarily for migration.

```elixir
# Migration: Add relative_path column
alter table(:media_files) do
  add :relative_path, :string
end

# Make relative_path NOT NULL later, after data migration
```

### Phase 2: Data Migration

**Challenge**: Determine which library path each media file belongs to based on its current absolute path.

#### 2.1 Identify Library Path for Each File

**Algorithm**:
```elixir
defmodule Mydia.Repo.Migrations.PopulateRelativePaths do
  def up do
    library_paths = Repo.all(LibraryPath)
    media_files = Repo.all(MediaFile)

    Enum.each(media_files, fn file ->
      # Find matching library path (longest prefix match)
      library_path = find_library_path_for_file(file.path, library_paths)

      if library_path do
        relative_path = Path.relative_to(file.path, library_path.path)

        # Update with library_path_id and relative_path
        update_media_file(file.id, library_path.id, relative_path)
      else
        # File is orphaned - log warning
        log_orphaned_file(file)
      end
    end)
  end

  defp find_library_path_for_file(file_path, library_paths) do
    library_paths
    |> Enum.filter(fn lp -> String.starts_with?(file_path, lp.path) end)
    |> Enum.max_by(fn lp -> String.length(lp.path) end, fn -> nil end)
  end
end
```

#### 2.2 Handle Edge Cases

**Orphaned Files**: Files that don't match any library path
- **Option A**: Delete them (aggressive)
- **Option B**: Keep them with NULL library_path_id (allow manual cleanup)
- **Recommendation**: Option B with admin UI warning

**Files Outside Library Paths**: Some files may have been manually added
- Keep absolute path as fallback
- Add validation warning

#### 2.3 Validate Migration

After migration:
```sql
-- Check for files without library_path_id
SELECT COUNT(*) FROM media_files WHERE library_path_id IS NULL;

-- Check for invalid relative paths
SELECT COUNT(*) FROM media_files WHERE relative_path IS NULL;

-- Validate path reconstruction
SELECT
  mf.id,
  mf.path as old_absolute,
  lp.path || '/' || mf.relative_path as new_absolute,
  mf.path = lp.path || '/' || mf.relative_path as matches
FROM media_files mf
JOIN library_paths lp ON lp.id = mf.library_path_id
WHERE mf.path != lp.path || '/' || mf.relative_path;
```

### Phase 3: Code Changes

#### 3.1 Update Schema (`lib/mydia/library/media_file.ex`)

```elixir
schema "media_files" do
  field :path, :string              # DEPRECATED - kept for migration
  field :relative_path, :string     # NEW - primary storage

  belongs_to :library_path, Mydia.Settings.LibraryPath  # NEW
  belongs_to :media_item, Mydia.Media.MediaItem
  belongs_to :episode, Mydia.Media.Episode
  # ...
end

def changeset(media_file, attrs) do
  media_file
  |> cast(attrs, [:relative_path, :library_path_id, ...])
  |> validate_required([:relative_path, :library_path_id])
  |> foreign_key_constraint(:library_path_id)
  # ...
end

# New function: Resolve absolute path from relative path
def absolute_path(%MediaFile{} = file) do
  if file.library_path do
    Path.join(file.library_path.path, file.relative_path)
  else
    # Fallback for orphaned files or during migration
    file.path
  end
end
```

#### 3.2 Update Import Job (`lib/mydia/jobs/media_import.ex`)

**Changes**:
- Calculate relative path instead of storing absolute
- Store library_path_id reference
- Use relative path in all file operations

```elixir
defp create_media_file_record(dest_path, size, episode, download, library_path) do
  # Calculate relative path
  relative_path = Path.relative_to(dest_path, library_path.path)

  attrs = %{
    relative_path: relative_path,     # NEW: store relative
    library_path_id: library_path.id, # NEW: store reference
    # path: dest_path,                # DEPRECATED: remove later
    size: file_metadata.size || size,
    # ...
  }

  Library.create_media_file(attrs)
end
```

#### 3.3 Update Stream Controller (`lib/mydia_web/controllers/api/stream_controller.ex`)

**Changes**:
- Resolve absolute path before accessing file
- Preload library_path association

```elixir
def show(conn, %{"id" => id}) do
  # Preload library_path for path resolution
  media_file = Library.get_media_file!(id, preload: [:library_path])

  conn
  |> assign(:media_file, media_file)
  |> stream_media_file(media_file)
end

defp stream_media_file(conn, media_file) do
  # Resolve absolute path from relative path + library path
  absolute_path = MediaFile.absolute_path(media_file)

  if File.exists?(absolute_path) do
    route_stream(conn, media_file, absolute_path)
  else
    # Handle missing file
    # ...
  end
end

defp stream_file_direct(conn, media_file, file_path) do
  # Use provided file_path instead of media_file.path
  file_stat = File.stat!(file_path)
  # ...
end
```

#### 3.4 Update Library Scanning (`lib/mydia/library.ex`)

**Changes**:
- Convert absolute paths to relative before storing
- Pass library_path_id when creating files
- Update path comparison logic

```elixir
defp create_media_files_for_scan_results(scan_result, media_item, library_path) do
  Enum.each(scan_result.files, fn file_info ->
    # Calculate relative path
    relative_path = Path.relative_to(file_info.path, library_path.path)

    attrs = %{
      relative_path: relative_path,
      library_path_id: library_path.id,
      # Determine media_item_id or episode_id
      # ...
    }

    create_media_file(attrs)
  end)
end
```

#### 3.5 Update File Lookup Functions

**Changes**:
- Add functions to query by relative path
- Update absolute path queries to resolve and compare

```elixir
# NEW: Get media file by relative path and library
def get_media_file_by_relative_path(relative_path, library_path_id, opts \\ []) do
  MediaFile
  |> where([f], f.relative_path == ^relative_path and f.library_path_id == ^library_path_id)
  |> maybe_preload(opts[:preload])
  |> Repo.one()
end

# UPDATED: Get by absolute path (backwards compatible)
def get_media_file_by_path(path, opts \\ []) do
  # Try to find by resolving library path + relative path
  # This requires joining with library_paths
  library_paths = Settings.list_library_paths()

  # Find matching library path
  library_path = find_library_path_for_file(path, library_paths)

  if library_path do
    relative_path = Path.relative_to(path, library_path.path)
    get_media_file_by_relative_path(relative_path, library_path.id, opts)
  else
    # Fallback: query by absolute path (for orphaned files)
    MediaFile
    |> where([f], f.path == ^path)
    |> maybe_preload(opts[:preload])
    |> Repo.one()
  end
end
```

#### 3.6 Library Path Validation

**New Feature**: Validate library path changes won't break existing files

```elixir
# lib/mydia/settings.ex
def update_library_path(%LibraryPath{} = library_path, attrs) do
  # Validate path change
  new_path = Map.get(attrs, :path) || Map.get(attrs, "path")

  if new_path && new_path != library_path.path do
    # Path is changing - validate new location
    with :ok <- validate_new_library_path(library_path, new_path) do
      library_path
      |> LibraryPath.changeset(attrs)
      |> Repo.update()
    end
  else
    # Path not changing - normal update
    library_path
    |> LibraryPath.changeset(attrs)
    |> Repo.update()
  end
end

defp validate_new_library_path(library_path, new_path) do
  # Check if files would be accessible at new location
  sample_files =
    Library.list_media_files(library_path_id: library_path.id)
    |> Enum.take(10)

  missing_files =
    Enum.reject(sample_files, fn file ->
      new_absolute = Path.join(new_path, file.relative_path)
      File.exists?(new_absolute)
    end)

  if missing_files == [] do
    :ok
  else
    {:error, "Files not found at new location. Please ensure media files are moved first."}
  end
end
```

### Phase 4: Testing Strategy

#### 4.1 Unit Tests

```elixir
# test/mydia/library/media_file_test.exs
describe "absolute_path/1" do
  test "resolves absolute path from relative path and library path" do
    library_path = library_path_fixture(%{path: "/media/movies"})
    media_file = media_file_fixture(%{
      relative_path: "The Matrix (1999)/movie.mkv",
      library_path_id: library_path.id
    })

    assert MediaFile.absolute_path(media_file) ==
      "/media/movies/The Matrix (1999)/movie.mkv"
  end

  test "handles orphaned files with fallback to old path" do
    media_file = media_file_fixture(%{
      path: "/old/location/movie.mkv",
      relative_path: nil,
      library_path_id: nil
    })

    assert MediaFile.absolute_path(media_file) == "/old/location/movie.mkv"
  end
end
```

#### 4.2 Integration Tests

```elixir
# test/mydia/library_test.exs
describe "library path relocation" do
  test "files remain accessible after library path change" do
    # Setup
    library_path = library_path_fixture(%{path: "/media/movies", type: :movies})
    media_item = media_item_fixture(%{type: "movie", title: "Test Movie"})

    # Create media file with relative path
    media_file = media_file_fixture(%{
      relative_path: "Test Movie (2020)/movie.mkv",
      library_path_id: library_path.id,
      media_item_id: media_item.id
    })

    # Update library path
    {:ok, updated_library_path} =
      Settings.update_library_path(library_path, %{path: "/new/media/movies"})

    # Reload media file
    reloaded = Library.get_media_file!(media_file.id, preload: [:library_path])

    # Verify absolute path now points to new location
    assert MediaFile.absolute_path(reloaded) ==
      "/new/media/movies/Test Movie (2020)/movie.mkv"
  end
end
```

#### 4.3 Migration Tests

```elixir
# test/mydia/repo/migrations/migrate_to_relative_paths_test.exs
describe "relative path migration" do
  test "correctly identifies library path for files" do
    # Create test data with absolute paths
    # Run migration
    # Verify relative paths and library_path_ids are correct
  end

  test "handles orphaned files gracefully" do
    # Create file outside any library path
    # Run migration
    # Verify file is marked as orphaned
  end
end
```

### Phase 5: Rollout Plan

#### 5.1 Pre-Migration Checks

1. **Backup database**: Critical before schema changes
2. **Verify all library paths exist**: Check filesystem
3. **Count orphaned files**: Files outside library paths
4. **Disk space check**: Ensure enough space for backups

#### 5.2 Migration Execution

**Step 1**: Schema changes (add columns, non-breaking)
```bash
mix ecto.migrate
```

**Step 2**: Data migration (populate new columns)
```bash
mix ecto.migrate  # Run data population migration
```

**Step 3**: Validation (verify data integrity)
```bash
# Run custom validation script
mix run priv/repo/scripts/validate_relative_paths.exs
```

**Step 4**: Code deployment (use new columns)
- Deploy application code that uses relative paths
- Keep absolute path column for backwards compatibility

**Step 5**: Monitoring (24-48 hours)
- Monitor error rates
- Check for missing files
- Validate playback success rate

**Step 6**: Cleanup (after validation)
- Remove deprecated `path` column (optional, can keep for safety)
- Remove migration code
- Update documentation

#### 5.3 Rollback Plan

If issues arise:

**Before Code Deployment**:
- Restore database backup
- Revert migrations
- Resume operations on old schema

**After Code Deployment**:
- Redeploy previous application version
- Database still has both columns
- System falls back to absolute path

## Risk Assessment

### High Risk Areas

1. **Data Loss**: Migration errors could corrupt file references
   - **Mitigation**: Full database backup, staged rollout

2. **Downtime**: Migration may lock tables
   - **Mitigation**: Run during low-traffic window, test on copy first

3. **Orphaned Files**: Files outside library paths become inaccessible
   - **Mitigation**: Pre-migration report, admin UI for cleanup

4. **Path Separator Issues**: Windows vs Unix path separators
   - **Mitigation**: Use `Path.join/2` consistently, test on both platforms

### Medium Risk Areas

1. **Performance**: Joining library_paths table adds query overhead
   - **Mitigation**: Add indexes, benchmark queries, consider preloading

2. **Complex Queries**: Path-based queries become more complex
   - **Mitigation**: Create helper functions, add database views

3. **External Integrations**: Third-party tools may expect absolute paths
   - **Mitigation**: Keep absolute path column, add API compatibility layer

### Low Risk Areas

1. **Config Changes**: Library path updates are rare
2. **User Impact**: Transparent to end users if done correctly
3. **Development**: Code changes are localized and testable

## Alternatives Considered

### Alternative 1: Path Rewriting on Library Change

**Approach**: When library path changes, update all media_file paths in bulk
```sql
UPDATE media_files
SET path = REPLACE(path, '/old/path', '/new/path')
WHERE path LIKE '/old/path/%'
```

**Pros**:
- Simpler implementation
- No schema changes needed
- Works with existing code

**Cons**:
- Dangerous bulk operation
- No rollback if paths wrong
- Doesn't handle complex path changes
- Race conditions during update
- Can't validate before update

**Verdict**: ❌ Rejected - Too risky, doesn't solve root cause

### Alternative 2: Virtual Filesystem Layer

**Approach**: Create abstraction layer that maps logical paths to physical paths
```elixir
defmodule Mydia.VFS do
  def resolve_path(logical_path) do
    # Map logical path to physical location
  end
end
```

**Pros**:
- Very flexible
- Could support multiple backends
- Clean separation of concerns

**Cons**:
- Over-engineered for current needs
- Performance overhead on every file access
- Complex to implement and maintain
- Requires caching layer

**Verdict**: ❌ Rejected - Too complex for problem at hand

### Alternative 3: Symlink-Based Approach

**Approach**: Create symlinks when library path changes
```bash
ln -s /new/media/movies /old/media/movies
```

**Pros**:
- No code changes needed
- Works at filesystem level
- Easy to set up

**Cons**:
- Requires OS-level permissions
- Not portable (Windows support)
- Doesn't work in containers
- Hidden complexity
- Doesn't solve root cause

**Verdict**: ❌ Rejected - Not a software solution

## Recommended Approach

**Use relative paths with library_path_id foreign key** (Proposed Solution)

**Justification**:
1. ✅ **Solves root cause**: Library paths can change without breaking files
2. ✅ **Data integrity**: Foreign key ensures valid references
3. ✅ **Explicit relationships**: Clear which files belong to which library
4. ✅ **Future-proof**: Supports multiple library paths, migration, etc.
5. ✅ **Testable**: Easy to write comprehensive tests
6. ✅ **Rollback safe**: Keep old column during transition

## Implementation Estimates

| Phase | Effort | Risk | Dependencies |
|-------|--------|------|--------------|
| 1. Schema Changes | 1 day | Low | None |
| 2. Data Migration | 2-3 days | High | Phase 1 |
| 3. Code Changes | 3-5 days | Medium | Phase 2 |
| 4. Testing | 2-3 days | Medium | Phase 3 |
| 5. Rollout | 1 day | High | Phase 4 |
| **Total** | **9-13 days** | **High** | Sequential |

## Success Criteria

1. ✅ All media files have valid relative_path and library_path_id
2. ✅ Zero files become inaccessible after migration
3. ✅ Library path can be updated without breaking playback
4. ✅ All tests pass (unit, integration, migration)
5. ✅ Performance benchmarks within 10% of baseline
6. ✅ Orphaned files are identified and reported to admin
7. ✅ Rollback capability exists and is tested

## Open Questions

1. **Should we keep the absolute `path` column long-term?**
   - Pro: Safety net for rollback, backwards compatibility
   - Con: Data duplication, potential for inconsistency
   - **Recommendation**: Keep for 6 months, then deprecate

2. **How to handle files added before migration?**
   - Option A: Require re-scanning library
   - Option B: Automatic migration (preferred)
   - **Recommendation**: Automatic migration with validation

3. **Should library path deletions cascade to media files?**
   - Pro: Clean data, no orphans
   - Con: Accidental deletion loses all file records
   - **Recommendation**: CASCADE with confirmation UI

4. **How to handle Windows paths (backslashes)?**
   - Store with forward slashes internally
   - Convert on read/write for Windows systems
   - **Recommendation**: Normalize to forward slashes in database

## References

- Current Implementation: `lib/mydia/library/media_file.ex`
- Import Logic: `lib/mydia/jobs/media_import.ex`
- Streaming: `lib/mydia_web/controllers/api/stream_controller.ex`
- Config System: `lib/mydia/config/loader.ex`
- Schema: `priv/repo/migrations/20251104023003_create_media_files.exs`
