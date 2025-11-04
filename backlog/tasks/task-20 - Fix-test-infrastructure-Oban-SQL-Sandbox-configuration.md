---
id: task-20
title: 'Fix test infrastructure: Oban/SQL Sandbox configuration'
status: Done
assignee: []
created_date: '2025-11-04 03:28'
updated_date: '2025-11-04 03:35'
labels:
  - testing
  - infrastructure
  - oban
  - bug
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Tests cannot run due to a pool configuration conflict between Oban and Ecto.Adapters.SQL.Sandbox. The error occurs in test_helper.exs when trying to set sandbox mode:

```
** (RuntimeError) cannot invoke sandbox operation with pool DBConnection.ConnectionPool.
To use the SQL Sandbox, configure your repository pool as:

    pool: Ecto.Adapters.SQL.Sandbox
```

The issue is that Oban starts with DBConnection.ConnectionPool in test environment, conflicting with the SQL Sandbox requirement. While config/test.exs has `config :mydia, Oban, testing: :manual`, this doesn't fully prevent the pool conflict.

Need to properly configure the test environment so that:
1. Ecto.Adapters.SQL.Sandbox can be used for test isolation
2. Oban doesn't interfere with test database connections
3. Tests can run successfully with `mix test`
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 mix test runs without SQL Sandbox errors
- [x] #2 Oban properly configured for test environment
- [x] #3 Test support files load without warnings
- [x] #4 All existing tests pass (or failing tests are documented)
- [x] #5 Documentation added for test setup if needed
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Solution Summary

The test infrastructure failure was caused by two issues:

1. **MIX_ENV hardcoded in docker-compose**: The `compose.yml` file set `MIX_ENV: dev` as an environment variable, which prevented the test configuration from loading.

2. **Oban starting unconditionally**: Even with `testing: :manual` in config, Oban was being added to the supervision tree, which tried to use the Repo before SQL Sandbox could configure it.

## Changes Made

### 1. Modified `lib/mydia/application.ex`
- Added `oban_children/0` private function that conditionally excludes Oban when `testing: :manual` is configured
- This prevents Oban from starting in test environment and conflicting with SQL Sandbox

### 2. Updated `dev` script
- Modified the `test` command to:
  - Set `MIX_ENV=test` explicitly when running tests
  - Run `mix clean` to clear dev-compiled code
  - Run `mix ecto.create --quiet && mix ecto.migrate --quiet` to ensure test database exists
  - Run `mix test` with proper environment

### 3. Fixed test assertion
- Updated `test/mydia_web/controllers/page_controller_test.exs` to match new page content ("Welcome to Mydia" instead of default Phoenix message)

## Result

All 18 tests now pass successfully with 0 failures. The test infrastructure is fully functional and ready for development.

## Solution Summary

### Root Cause
The test infrastructure was failing because:
1. The `application.ex` file had broken environment detection for Oban (`Application.get_env(:mydia, :env)` was never set)
2. The `./dev test` script didn't set `MIX_ENV=test`, causing tests to run with dev configuration

### Fixes Applied
1. **Fixed Oban conditional startup** (`lib/mydia/application.ex:41-52`)
   - Changed from checking undefined `:env` config to checking Oban's `testing: :manual` flag
   - Now properly skips Oban startup when `testing: :manual` is set in config/test.exs

2. **Fixed dev script** (`dev:153`)
   - Changed from `run_in_container mix test` to `docker compose exec -e MIX_ENV=test`
   - Now properly sets test environment when running tests

3. **Fixed test warnings**:
   - Updated page controller test to check for actual content ("Welcome to Mydia")
   - Removed unused `:let={f}` variable in session template
   - Fixed duplicate @doc warnings in UserAuth by using function head pattern

### Verification
- All 18 tests now pass with 0 failures
- No warnings during test compilation or execution
- SQL Sandbox working correctly for test isolation
<!-- SECTION:NOTES:END -->
