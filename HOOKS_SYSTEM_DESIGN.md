# Hooks System Design for Mydia

## Executive Summary

This document outlines the design for an extensible hooks/plugin system that allows users to customize Mydia's behavior at key lifecycle events. The system prioritizes safety, performance, and developer experience while enabling powerful customization.

---

## 1. Lifecycle Hook Points

Based on codebase analysis, we've identified 7 major categories of hook points:

### 1.1 Media Addition Hooks
- **`before_media_added`**: Before media item is created in database
  - Location: `Mydia.Media.create_media_item/1` (media.ex:54-58)
  - Data: media_item changeset (type, title, tmdb_id, year, monitored)
  - Use case: Validate/modify media settings before creation

- **`after_media_added`**: After successful media item creation
  - Location: `Mydia.Media.create_media_item/1` (media.ex:54-58)
  - Data: created media_item struct with ID
  - Use case: Trigger external notifications, adjust settings

### 1.2 Import Hooks
- **`before_import_started`**: Before file import begins
  - Location: `Mydia.Jobs.MediaImport.perform/1` (jobs/media_import.ex:42)
  - Data: download record, source path
  - Use case: Pre-processing, validation

- **`after_import_completed`**: After successful file import
  - Location: `Mydia.Jobs.MediaImport.perform/1` (jobs/media_import.ex:75-86)
  - Data: download, media_file, destination path
  - Use case: Post-processing, external indexing

- **`on_import_failed`**: When import fails
  - Location: `Mydia.Jobs.MediaImport.perform/1` (jobs/media_import.ex:88-95)
  - Data: download, error message
  - Use case: Error recovery, notifications

### 1.3 Download Hooks
- **`before_download_initiated`**: Before download is sent to client
  - Location: `Mydia.Downloads.initiate_download/2` (downloads.ex:245-256)
  - Data: search_result, media associations, client config
  - Use case: Modify download URL, adjust client settings

- **`after_download_initiated`**: After download successfully started
  - Location: `Mydia.Downloads.initiate_download/2` (downloads.ex:245-256)
  - Data: created download record
  - Use case: External tracking, notifications

- **`on_download_completed`**: When download finishes
  - Location: `Mydia.Jobs.DownloadMonitor.handle_completion/1` (jobs/download_monitor.ex:64-68)
  - Data: download with status, save_path, progress
  - Use case: Post-download processing, notifications

- **`on_download_failed`**: When download fails
  - Location: `Mydia.Jobs.DownloadMonitor.handle_failure/1` (jobs/download_monitor.ex:108)
  - Data: download, error_message
  - Use case: Retry logic, error notifications

### 1.4 Episode Status Hooks
- **`after_episode_updated`**: After episode update
  - Location: `Mydia.Media.update_episode/2` (media.ex:243-247)
  - Data: episode, changed attributes
  - Use case: Track watch history, external sync

- **`after_season_monitoring_changed`**: After season monitoring bulk update
  - Location: `Mydia.Media.update_season_monitoring/3` (media.ex:263-272)
  - Data: media_item_id, season_number, monitored, count
  - Use case: Adjust search schedules

### 1.5 Metadata Hooks
- **`before_metadata_enrichment`**: Before fetching metadata
  - Location: `Mydia.Library.MetadataEnricher.enrich/2` (library/metadata_enricher.ex:34)
  - Data: provider_id, type, match_result
  - Use case: Override provider selection

- **`after_metadata_enriched`**: After metadata fetched and saved
  - Location: `Mydia.Library.MetadataEnricher.enrich/2` (library/metadata_enricher.ex:49-60)
  - Data: media_item with full metadata
  - Use case: Custom metadata augmentation

- **`after_episodes_refreshed`**: After TV show episodes created
  - Location: `Mydia.Media.refresh_episodes_for_tv_show/2` (media.ex:451)
  - Data: media_item, episode count, season preference
  - Use case: Bulk episode adjustments

### 1.6 Search/Indexer Hooks
- **`before_automatic_search`**: Before background search executes
  - Location: `Mydia.Jobs.MovieSearch.search_movie/2` (jobs/movie_search.ex:108-136)
  - Data: media_item, search query
  - Use case: Modify search parameters

- **`after_automatic_search`**: After search completes
  - Location: `Mydia.Jobs.MovieSearch.search_movie/2` (jobs/movie_search.ex:108-136)
  - Data: media_item, search_results, selected_result
  - Use case: Custom result filtering/ranking

- **`on_no_results_found`**: When search returns no results
  - Location: `Mydia.Jobs.MovieSearch.search_movie/2` (jobs/movie_search.ex:120-125)
  - Data: media_item, search_query
  - Use case: Fallback search strategies

- **`after_release_ranked`**: After release ranking
  - Location: `Mydia.Indexers.ReleaseRanker.select_best_result/2` (referenced in movie_search.ex:149)
  - Data: all results, selected result, score breakdown
  - Use case: Override ranking logic

### 1.7 Administrative Hooks
- **`before_media_deleted`**: Before media item deletion
- **`after_media_deleted`**: After media item deletion
- **`before_download_cancelled`**: Before download cancellation
- **`after_download_cancelled`**: After download cancellation

---

## 2. Technology Comparison

### 2.1 WebAssembly (Wasmex)

**Pros:**
- Strong sandboxing with Wasmtime runtime
- Multi-language support (Rust, Go, C++, etc.)
- Near-native performance
- Mature security model (WASI)
- Active development in Elixir ecosystem (2025)

**Cons:**
- More complex to set up
- Requires compilation step for hooks
- Larger memory footprint
- Learning curve for hook developers

**Best for:** Performance-critical hooks, reusing existing code libraries

### 2.2 Lua (Luerl)

**Pros:**
- Pure BEAM implementation (no NIFs)
- Built-in sandboxing (`:luerl_sandbox`)
- Lightweight and fast
- Simple syntax, easy to learn
- Proven in gaming/config systems
- Recent improvements (Lua library v0.1.0, 2025)

**Cons:**
- Limited ecosystem compared to JS/Python
- Lua 5.3 compatibility only
- Less familiar to web developers

**Best for:** Configuration scripts, simple logic, embedded use cases

### 2.3 JavaScript/TypeScript (DenoEx)

**Pros:**
- Familiar to web developers
- TypeScript support built-in
- Rich ecosystem (npm packages)
- Modern async/await patterns
- V8 engine performance

**Cons:**
- External process overhead
- More complex deployment
- Higher memory usage
- Process management needed

**Best for:** Complex logic, web API integrations, familiar developer experience

### 2.4 Python (Pythonx/ErlPort)

**Pros:**
- Massive ecosystem (ML, data processing, web scraping)
- Familiar to data/ML engineers
- Rich standard library
- Good for integrations

**Cons:**
- GIL (Global Interpreter Lock) issues with Pythonx
- Process overhead with ErlPort
- Performance concerns
- Complex deployment

**Best for:** ML integrations, data processing, complex calculations

### 2.5 External Process Hooks

**Pros:**
- Language-agnostic (any executable)
- Simple to implement
- Strong isolation
- Familiar model (Sonarr/Radarr pattern)

**Cons:**
- Process startup overhead
- Limited data exchange (env vars + JSON)
- No bidirectional communication
- Harder to debug

**Best for:** Simple notifications, calling external tools

---

## 3. Recommended Approach: Hybrid System

### 3.1 Primary: Lua (Luerl) for Core Hooks

**Rationale:**
- Runs directly on BEAM (no external processes)
- Built-in sandboxing
- Low overhead
- Good balance of safety and power
- Simple for users to write

**Use cases:**
- Data transformations
- Conditional logic
- Settings adjustments
- Quick automations

### 3.2 Secondary: External Process for Complex Tasks

**Rationale:**
- Maximum flexibility
- Strong isolation
- Proven pattern from Sonarr/Radarr
- Easy for users familiar with shell scripts

**Use cases:**
- Calling external tools
- Complex integrations
- Language-specific libraries
- Long-running tasks

---

## 4. Hook Execution Model

### 4.1 Architecture Overview

```
┌──────────────────────────────────────────────────────────────┐
│                     Application Layer                         │
│  (Media.create_media_item, Downloads.initiate_download, etc) │
└─────────────────────────┬────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────────────────┐
│                   Mydia.Hooks.Manager                         │
│  - Hook registration                                          │
│  - Hook discovery                                             │
│  - Priority ordering                                          │
└─────────────────────────┬────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────────────────┐
│                   Mydia.Hooks.Executor                        │
│  - Data serialization                                         │
│  - Execution coordination                                     │
│  - Timeout management                                         │
│  - Error handling                                             │
└───────┬─────────────────┴──────────────────┬─────────────────┘
        │                                    │
        ▼                                    ▼
┌──────────────────────┐      ┌──────────────────────────────┐
│  Lua Hook Executor   │      │  External Process Executor   │
│  (Luerl sandbox)     │      │  (Port/System.cmd)           │
└──────────────────────┘      └──────────────────────────────┘
```

### 4.2 Hook Registration

Hooks are discovered from a configurable directory (default: `"hooks"` relative to database):

```
hooks/
├── after_media_added/
│   ├── 01_notify_plex.lua         # Priority prefix
│   ├── 02_adjust_anime_settings.lua
│   └── 99_external_webhook.sh
├── on_download_completed/
│   └── 01_post_process.lua
└── before_automatic_search/
    └── 01_anime_search_tweaks.lua
```

**Configuration:**
The hooks directory is configured in `config.yaml`:
```yaml
database:
  path: "/config/mydia.db"  # Or "mydia_dev.db" in development

hooks:
  enabled: true
  directory: "hooks"  # Relative to database directory
  default_timeout_ms: 5000
  max_timeout_ms: 30000
```

**Path Resolution:**
- Relative paths (like `"hooks"`) are resolved relative to the database directory
  - Development: `mydia_dev.db` + `hooks` = `./hooks`
  - Production: `/config/mydia.db` + `hooks` = `/data/hooks`
- Absolute paths (like `"/config/hooks"`) are used as-is

**Docker Deployment:**
Hooks live in the data volume alongside the database:
```yaml
# docker-compose.yml
services:
  mydia:
    image: mydia:latest
    volumes:
      - ./data:/data  # Contains database AND hooks
      - ./media:/media
```

This approach means:
- ✅ No path changes needed between dev and production
- ✅ Hooks backup with data automatically
- ✅ Simpler volume management in Docker

**Registration process:**
1. On application start, `Mydia.Hooks.Manager` resolves the hooks path
2. Scans the directory for event subdirectories
3. Hooks are grouped by event name (directory)
4. Within each event, hooks are sorted by filename prefix (priority)
5. Hook metadata is stored in ETS table for fast lookup
6. If hooks are disabled or directory doesn't exist, the system logs and continues gracefully

### 4.3 Data Flow

```
1. Lifecycle Event Triggered
   ↓
2. Manager.execute_hooks("after_media_added", data, opts)
   ↓
3. Serialize data to hook-friendly format
   ↓
4. For each registered hook (in priority order):
   │
   ├─→ Lua Hook:
   │   ├─→ Load script into Luerl sandbox
   │   ├─→ Set resource limits
   │   ├─→ Execute with timeout
   │   ├─→ Capture result/error
   │   └─→ Merge changes into data
   │
   └─→ External Process:
       ├─→ Prepare environment variables
       ├─→ Start process with timeout
       ├─→ Stream stdout/stderr
       ├─→ Parse JSON output
       └─→ Merge changes into data
   ↓
5. Aggregate results/errors
   ↓
6. Apply changes back to application context
```

### 4.4 Hook Interface

#### Lua Hook Structure

```lua
-- priv/hooks/after_media_added/02_adjust_anime_settings.lua

-- Hook metadata (optional)
hook = {
  name = "Anime Settings Adjuster",
  description = "Automatically adjusts quality and search settings for anime",
  author = "username",
  version = "1.0.0"
}

-- Main hook function (required)
function execute(event, context)
  -- Access event data
  local media = event.media_item
  local is_anime = string.find(string.lower(media.title), "anime")

  if not is_anime then
    return {modified = false}
  end

  -- Modify settings
  return {
    modified = true,
    changes = {
      quality_profile = "Anime 1080p",
      preferred_release_groups = {"SubsPlease", "Erai-raws"},
      search_query_suffix = " -dubbed"
    },
    message = "Applied anime-specific settings"
  }
end
```

#### External Process Hook

```bash
#!/bin/bash
# priv/hooks/on_download_completed/01_post_process.sh

# Event data passed via environment variables
MEDIA_TITLE="$HOOK_MEDIA_TITLE"
FILE_PATH="$HOOK_FILE_PATH"
MEDIA_TYPE="$HOOK_MEDIA_TYPE"

# JSON input also available via stdin
EVENT_JSON=$(cat)

# Perform custom logic
echo "Processing: $MEDIA_TITLE" >&2

# Return JSON to stdout for result
cat <<EOF
{
  "modified": false,
  "message": "Post-processing completed"
}
EOF

exit 0
```

### 4.5 Error Handling

**Error Categories:**

1. **Hook Load Error**: Hook file missing, syntax error
   - Action: Log error, skip hook, continue to next
   - Notification: User warning in UI

2. **Hook Execution Error**: Runtime error in hook code
   - Action: Log error with stack trace, skip hook, continue to next
   - Notification: User warning in UI

3. **Hook Timeout**: Execution exceeds time limit
   - Action: Kill hook, log timeout, continue to next
   - Notification: User warning in UI

4. **Hook Data Error**: Invalid return format
   - Action: Log error, ignore changes, continue to next
   - Notification: User warning in UI

**Error Handling Strategy:**
- **Fail-soft**: Errors in hooks never block the main application flow
- **Isolate failures**: One hook failure doesn't affect others
- **Detailed logging**: All errors captured with context for debugging
- **User visibility**: Hook errors shown in Settings > Hooks UI

### 4.6 Timeout Management

**Default Timeouts:**
- Lua hooks: 5 seconds
- External process hooks: 30 seconds
- Configurable per-hook via metadata

**Timeout Implementation:**
- Lua: Use `Task.async` with `Task.yield` and timeout
- External: Use `System.cmd` with `:timeout` option
- Background hooks: Use `Task.Supervisor` for supervision

### 4.7 Async vs Sync Execution

**Synchronous Hooks** (blocking):
- `before_*` hooks: Must complete before action proceeds
- `after_*` hooks when result needed: Changes applied before continuing
- Examples: `before_media_added`, `before_download_initiated`

**Asynchronous Hooks** (non-blocking):
- `after_*` hooks when result not needed: Fire and forget
- `on_*` notification hooks: Don't block main flow
- Examples: `on_download_completed`, `after_media_added` (notifications)

**Implementation:**
```elixir
# Sync execution
def execute_hooks_sync(event, data, opts) do
  hooks = get_hooks_for_event(event)

  Enum.reduce_while(hooks, {:ok, data}, fn hook, {:ok, acc_data} ->
    case execute_hook(hook, acc_data, opts) do
      {:ok, result} -> {:cont, {:ok, merge_changes(acc_data, result)}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end)
end

# Async execution
def execute_hooks_async(event, data, opts) do
  hooks = get_hooks_for_event(event)

  Task.Supervisor.async_stream_nolink(
    Mydia.HookSupervisor,
    hooks,
    fn hook -> execute_hook(hook, data, opts) end,
    timeout: opts[:timeout] || 30_000,
    on_timeout: :kill_task
  )
  |> Enum.to_list()

  :ok
end
```

### 4.8 Hook Priority and Chaining

**Priority System:**
- Hooks ordered by filename prefix: `01_first.lua`, `02_second.lua`, `99_last.lua`
- Lower numbers execute first
- Useful for dependencies between hooks

**Data Chaining:**
- Each hook receives the output of the previous hook
- Hooks can modify data that subsequent hooks see
- Example: Hook 01 adjusts quality, Hook 02 sees the adjusted quality

**Chain Termination:**
- Hook can return `{halt: true}` to stop chain
- Useful for validation hooks that prevent action
- Example: `before_media_added` hook rejects duplicate media

---

## 5. Security and Sandboxing

### 5.1 Lua Sandbox Features

**Luerl Built-in Sandboxing:**
- `:luerl_sandbox` module provides restricted environment
- Disabled functions: file I/O, network, process execution
- Allowed: pure computation, string manipulation, table operations

**Resource Limits:**
- **Memory**: Max Lua state size (configurable, default: 50MB)
- **CPU**: Execution timeout (default: 5s)
- **Instructions**: Max instruction count (prevents infinite loops)

**Implementation:**
```elixir
defmodule Mydia.Hooks.LuaExecutor do
  def execute(script, data, opts) do
    # Create sandboxed Lua state
    {:ok, state} = :luerl_sandbox.init()

    # Set resource limits
    state = :luerl_sandbox.set_limits(state, %{
      memory: opts[:max_memory] || 50_000_000,  # 50MB
      instructions: opts[:max_instructions] || 10_000_000
    })

    # Inject safe helper functions
    state = provide_safe_helpers(state)

    # Execute with timeout
    task = Task.async(fn ->
      :luerl_sandbox.dofile(script, state)
    end)

    case Task.yield(task, opts[:timeout] || 5_000) || Task.shutdown(task) do
      {:ok, result} -> {:ok, result}
      nil -> {:error, :timeout}
    end
  end

  defp provide_safe_helpers(state) do
    # Provide safe utilities: JSON, HTTP (rate-limited), logging
    # No file system, no arbitrary process execution
    state
  end
end
```

### 5.2 External Process Isolation

**Security Measures:**
- Run with limited user permissions (non-root)
- No sensitive environment variables passed
- Timeout enforcement
- Resource limits via OS (cgroups if available)

**Data Sanitization:**
- Validate all inputs before passing to hooks
- Escape shell arguments
- Limit data size passed to hooks

### 5.3 Hook Validation

**Pre-execution Checks:**
- Verify hook file permissions (owner, executable)
- Syntax validation for Lua scripts
- Checksum verification (optional, for production)
- Rate limiting per hook (prevent abuse)

---

## 6. Performance Considerations

### 6.1 Execution Overhead

**Lua Hooks:**
- Initialization: ~1-5ms (Luerl state creation)
- Execution: Variable (depends on script complexity)
- Total overhead: ~5-50ms for typical hooks

**External Process:**
- Process spawn: ~10-50ms
- Execution: Variable
- Total overhead: ~50-500ms for typical scripts

**Mitigation Strategies:**
- **Async execution**: Non-critical hooks run in background
- **Hook pooling**: Pre-initialize Lua states for hot paths
- **Selective execution**: Only run hooks when needed (conditional triggers)

### 6.2 Impact on Main Application

**Design Principles:**
- Hooks never block critical paths (except `before_*` validations)
- Use `Task.Supervisor` for fault isolation
- Hooks failures don't crash main processes
- Background job hooks run in dedicated worker pools

**Monitoring:**
- Track hook execution time
- Alert on slow hooks
- Per-hook performance metrics in UI

### 6.3 Scalability

**Concurrent Execution:**
- Multiple hooks for same event can run in parallel (if independent)
- Use `Task.async_stream` with max concurrency limit
- Prevents hook storms from overwhelming system

**Hook Caching:**
- Compiled Lua bytecode cached in ETS
- Hook metadata cached
- Reduces load time on subsequent executions

---

## 7. Hook API Design

### 7.1 Event Data Structure

All hooks receive a consistent data structure:

```elixir
%{
  # Event metadata
  event: "after_media_added",
  timestamp: ~U[2025-11-05 12:00:00Z],

  # Event-specific data (varies by event)
  media_item: %{
    id: 123,
    type: "tv_show",
    title: "Attack on Titan",
    tmdb_id: 1429,
    year: 2013,
    monitored: true,
    metadata: %{...}
  },

  # Context (useful for all hooks)
  context: %{
    user_id: 1,  # If triggered by user action
    settings: %{...},  # Relevant app settings
    dry_run: false  # Test mode flag
  }
}
```

### 7.2 Hook Return Format

Hooks return a standardized result:

```elixir
%{
  # Required
  modified: true,  # Whether hook made changes

  # Optional: changes to apply
  changes: %{
    # Nested structure mirroring input
    media_item: %{
      monitored: false
    }
  },

  # Optional: metadata for logging/UI
  message: "Applied anime settings",
  metadata: %{...},

  # Optional: control flow
  halt: false  # Stop executing subsequent hooks
}
```

### 7.3 Safe Helper Functions

Provided to Lua hooks for common tasks:

**JSON Operations:**
```lua
-- Parse JSON string
obj = json.decode('{"key": "value"}')

-- Encode to JSON
str = json.encode({key = "value"})
```

**HTTP Requests (rate-limited):**
```lua
-- GET request
response = http.get("https://api.example.com/data")

-- POST request
response = http.post("https://api.example.com/webhook", {
  body = json.encode({event = "test"}),
  headers = {["Content-Type"] = "application/json"}
})
```

**Logging:**
```lua
-- Log messages (visible in hook logs)
log.info("Processing media: " .. media.title)
log.warn("Quality profile not set")
log.error("Failed to process")
```

**Utilities:**
```lua
-- String utilities
text = string.lower(media.title)
matched = string.match(text, "anime")

-- Table utilities
size = table.length(results)
item = table.find(results, function(r) return r.quality == "1080p" end)
```

---

## 8. User Experience

### 8.1 Hook Development Workflow

**1. Create Hook File:**

For local development:
```bash
# Hooks directory is relative to database location
mkdir -p hooks/after_media_added
touch hooks/after_media_added/01_my_hook.lua
```

For Docker deployments:
```bash
# On the Docker host machine (in your data volume)
mkdir -p ./data/hooks/after_media_added
touch ./data/hooks/after_media_added/01_my_hook.lua
```

Or directly in the container:
```bash
docker exec -it mydia mkdir -p /data/hooks/after_media_added
docker exec -it mydia touch /data/hooks/after_media_added/01_my_hook.lua
```

**2. Write Hook Logic:**
```lua
function execute(event, context)
  local media = event.media_item

  -- Your logic here

  return {
    modified = false,
    message = "Hook executed"
  }
end
```

**3. Test Hook:**
- Use built-in hook tester in UI: Settings > Hooks > Test Hook
- Provide sample data
- View execution result and logs

**4. Deploy:**
- Hooks are automatically discovered on app restart
- Hot reload option (development mode)

### 8.2 Hook Management UI

**Features:**
- List all discovered hooks grouped by event
- Enable/disable individual hooks
- View hook metadata (name, description, author)
- View execution history and errors
- Test hooks with sample data
- Hook performance metrics

**Settings Page:**
- Global hook timeout settings
- Resource limit configuration
- Hook execution logs
- Error notifications

### 8.3 Documentation

**Comprehensive docs covering:**
- Available hook points and data structures
- Lua API reference
- External process hook guide
- Example hooks (common use cases)
- Troubleshooting guide
- Security best practices

**In-app examples:**
- Template hooks for each event type
- Commented examples showing common patterns
- Copy-paste ready snippets

---

## 9. Proof of Concept

### 9.1 Target Hook Point

**Hook:** `after_media_added`
**Location:** `Mydia.Media.create_media_item/1`

**Rationale:**
- Simple, well-defined event
- Clear input/output
- Non-critical (safe to experiment)
- Useful for real use cases

### 9.2 Implementation Plan

**Phase 1: Core Infrastructure**
1. Create `Mydia.Hooks.Manager` GenServer
2. Implement hook discovery from `priv/hooks/`
3. Create `Mydia.Hooks.Executor` module
4. Add hook execution to `create_media_item/1`

**Phase 2: Lua Execution**
1. Add `luerl` dependency
2. Implement `Mydia.Hooks.LuaExecutor`
3. Create sandbox environment with safe helpers
4. Add timeout and error handling

**Phase 3: Testing & Examples**
1. Write example `after_media_added` hook
2. Create test suite for hook execution
3. Add logging and metrics
4. Document the hook API

**Phase 4: UI (Future)**
1. Settings page for hook management
2. Hook testing interface
3. Execution logs viewer

### 9.3 Example Use Case

**Anime Settings Auto-Adjuster:**

When a TV show is added with "anime" in the title:
- Set quality profile to "Anime 1080p"
- Prefer specific release groups
- Adjust search parameters
- Enable subtitle monitoring

**Hook Implementation:**
```lua
function execute(event, context)
  local media = event.media_item

  if media.type ~= "tv_show" then
    return {modified = false}
  end

  local title_lower = string.lower(media.title)
  local is_anime = string.find(title_lower, "anime") ~= nil
                or string.find(title_lower, "attack on titan") ~= nil

  if not is_anime then
    return {modified = false}
  end

  log.info("Detected anime TV show: " .. media.title)

  return {
    modified = true,
    changes = {
      media_item = {
        quality_profile = "Anime 1080p",
        preferred_release_groups = {"SubsPlease", "Erai-raws", "HorribleSubs"},
        search_settings = {
          prefer_subbed = true,
          exclude_dubbed = true
        }
      }
    },
    message = "Applied anime-specific settings"
  }
end
```

---

## 10. Implementation Roadmap

### Phase 1: Foundation (Week 1-2)
- [ ] Add `luerl` dependency to mix.exs
- [ ] Create `Mydia.Hooks` context module structure
- [ ] Implement `Hooks.Manager` for hook discovery and registration
- [ ] Implement `Hooks.Executor` for execution coordination
- [ ] Add ETS tables for hook metadata caching

### Phase 2: Lua Execution (Week 2-3)
- [ ] Implement `Hooks.LuaExecutor` with Luerl
- [ ] Create sandboxed Lua environment
- [ ] Add safe helper functions (JSON, HTTP, logging)
- [ ] Implement timeout and resource limits
- [ ] Add comprehensive error handling

### Phase 3: Integration (Week 3-4)
- [ ] Integrate hook execution into `after_media_added`
- [ ] Add hook logging infrastructure
- [ ] Create example hooks in `priv/hooks/`
- [ ] Write integration tests

### Phase 4: Documentation & Polish (Week 4-5)
- [ ] Write developer documentation
- [ ] Create hook API reference
- [ ] Add in-app examples
- [ ] Performance optimization

### Phase 5: UI (Future - Week 6+)
- [ ] Hook management Settings page
- [ ] Hook testing interface
- [ ] Execution logs viewer
- [ ] Performance metrics dashboard

### Phase 6: External Process Support (Future)
- [ ] Implement `Hooks.ExternalExecutor`
- [ ] Add environment variable passing
- [ ] JSON stdin/stdout handling
- [ ] Process timeout management

### Phase 7: Additional Hook Points (Future)
- [ ] Gradually add hooks to other lifecycle events
- [ ] Document each new hook point
- [ ] Provide examples for common use cases

---

## 11. Open Questions & Future Considerations

### 11.1 Open Questions

1. **Hook versioning**: How to handle hook API changes?
   - Proposed: Version in hook metadata, maintain backwards compatibility

2. **Hook dependencies**: Can hooks depend on each other?
   - Proposed: Not in v1, use priority ordering for now

3. **Hook marketplace**: Community hub for sharing hooks?
   - Proposed: Future consideration, focus on local hooks first

4. **Database modifications**: Should hooks modify DB directly?
   - Proposed: No, hooks return changes, app applies them

### 11.2 Future Enhancements

1. **WebAssembly support**: Add Wasmex for performance-critical hooks
2. **Hook analytics**: Detailed metrics and insights
3. **Hook debugging**: Interactive debugger in UI
4. **Hook templates**: Visual hook builder for common patterns
5. **Multi-tenant hooks**: Different hooks per user/library
6. **Remote hooks**: Execute hooks on remote services (webhooks++)

---

## 12. Conclusion

This hooks system design provides a solid foundation for extensibility in Mydia. By starting with Lua (Luerl) for embedded hooks and providing a path to external processes for complex scenarios, we balance:

- **Safety**: Strong sandboxing and resource limits
- **Performance**: Low overhead with async execution where possible
- **Developer Experience**: Simple API, good documentation, testing tools
- **Flexibility**: Support for wide range of use cases

The proof-of-concept implementation will validate the design and provide a template for expanding to additional hook points throughout the application.
