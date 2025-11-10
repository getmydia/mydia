---
id: task-149.3
title: Skip or deprioritize special episode (S00) searches
status: Done
assignee:
  - arosenfeld
created_date: '2025-11-10 18:25'
updated_date: '2025-11-10 18:36'
labels:
  - enhancement
  - configuration
  - usenet
dependencies: []
parent_task_id: task-149
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Stop wasting API quota on special episodes that rarely exist on indexers.

**Current Issue:**
- S00 episodes searched with same priority as regular episodes
- Success rate typically <5%
- Can be 50+ episodes per show

**Implementation Options:**
1. Skip S00 entirely by default with opt-in setting
2. Search S00 only when explicitly requested by user
3. Deprioritize S00 (search only after all regular episodes found)
4. Reduce S00 search frequency (once per week vs every run)

**Recommended:**
- Add config option: `monitor_special_episodes` (default: false)
- Filter out season 0 in `process_episodes_with_smart_logic/3`
- Allow manual search override for S00
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Complete

**Changes Made:**

1. **Configuration** (config/config.exs:122-125)
   - Added `monitor_special_episodes: false` to episode_monitor config
   - Default false due to <5% success rate on indexers
   - Can be set to true to enable S00 monitoring
   - Manual searches via UI always work regardless of config

2. **Helper Functions** (tv_show_search.ex:988-1014)
   - `monitor_special_episodes?/0` - Reads config setting
   - `filter_special_episodes/1` - Filters S00 episodes when disabled
   - Logs count of skipped special episodes for visibility

3. **Automated Search Filtering** (tv_show_search.ex:350-385)
   - Updated `load_monitored_episodes_without_files/0` to filter S00
   - Updated `load_episodes_for_show/1` to filter S00
   - Both functions now call `filter_special_episodes/1`

4. **Manual Search Preservation**
   - `load_episodes_for_season/2` - NOT filtered (manual season search)
   - `load_episode/1` - NOT filtered (manual specific episode search)
   - Users can still search S00 episodes manually via UI buttons

**Testing:**
- All 24 TV show search tests pass
- Code compiles without errors
- Logging present when S00 episodes are skipped

**Impact:**
For shows with 50+ special episodes (like Bluey with S00E01-S00E152), this eliminates ~30% of API calls by default, focusing quota on regular episodes that have much higher success rates. Users can still manually search specials when needed.
<!-- SECTION:NOTES:END -->
