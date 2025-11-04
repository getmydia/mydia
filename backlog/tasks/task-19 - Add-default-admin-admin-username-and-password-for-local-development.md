---
id: task-19
title: Add default admin/admin username and password for local development
status: Done
assignee:
  - Claude
created_date: '2025-11-04 03:25'
updated_date: '2025-11-04 03:30'
labels:
  - authentication
  - development
  - enhancement
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Create a default admin user (username: admin, password: admin) that is automatically seeded in development and test environments for easy local authentication.

This should:
- Only be created in dev/test environments (never production)
- Use the local authentication system (SessionController)
- Be properly hashed using Argon2
- Have admin role assigned
- Be documented in README for developers

This provides an easy out-of-the-box experience for local development without requiring OIDC setup.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Default admin user is created when running mix ecto.setup or mix ecto.reset in dev/test environments
- [x] #2 Can successfully log in with admin/admin credentials via local auth
- [x] #3 Admin user has admin role assigned
- [x] #4 Seeds script checks environment and only creates user in dev/test
- [x] #5 README documents the default credentials
- [x] #6 User creation is idempotent (doesn't fail if user already exists)
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
## Implementation Plan

### Key Files to Modify
1. **priv/repo/seeds.exs** - Add admin user creation logic
2. **README.md** - Document default credentials

### Implementation Steps

1. **Update seeds.exs**:
   - Check environment using `Mix.env()` to ensure we're in `:dev` or `:test`
   - Use `Mydia.Accounts.get_user_by_username/1` to check if admin already exists (idempotent)
   - If not exists, create admin user with:
     - username: "admin"
     - email: "admin@localhost"
     - password: "admin" (will be hashed automatically via User.changeset)
     - role: "admin"
   - Print success/skip message for visibility

2. **Update README.md**:
   - Add a new "Authentication" or "Development Credentials" section
   - Document the default admin/admin credentials
   - Note that these only work in dev/test environments

### Technical Notes
- The code currently uses **Bcrypt** for password hashing (not Argon2 as mentioned in task description)
- The `User.changeset/2` automatically hashes passwords via the `hash_password/1` private function
- Seeds run when: `mix ecto.setup`, `mix ecto.reset`, or manually with `mix run priv/repo/seeds.exs`
- Idempotency is handled by checking if user exists before creating
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Complete

### Changes Made:
1. **priv/repo/seeds.exs** - Added admin user creation logic with environment check and idempotency
2. **README.md** - Added Authentication section documenting default admin/admin credentials
3. **lib/mydia/accounts/user.ex** - Fixed login_changeset to truncate microseconds (bug discovered during testing)

### Testing Results:
- ✅ Seeds script creates admin user successfully
- ✅ Idempotency works - running seeds twice skips existing user
- ✅ Admin user has correct role: "admin"
- ✅ Password hashing works (Bcrypt)
- ✅ Password verification returns true for "admin" password
- ✅ Environment check works (only creates in dev/test)

### Bug Fixed:
Discovered and fixed issue where `login_changeset` was using `DateTime.utc_now()` which includes microseconds, causing an error with SQLite's `:utc_datetime` type. Fixed by truncating to seconds: `DateTime.utc_now() |> DateTime.truncate(:second)`

## Implementation Complete

Successfully implemented default admin/admin credentials for local development:

### What Was Done
1. **seeds.exs**: Added logic to create admin user in dev/test environments only
   - Checks `Mix.env() in [:dev, :test]`
   - Creates user with username: admin, password: admin, role: admin
   - Idempotent - skips if user already exists
   - Provides clear success/skip messages

2. **README.md**: Documented the default credentials
   - Added Authentication section with username/password
   - Clearly noted it's dev/test only

### Verification
- ✓ Database reset creates admin user successfully
- ✓ Admin user has correct role, email, and display name
- ✓ Password verification works correctly (Bcrypt)
- ✓ Seeds are idempotent (skip creation if user exists)
- ✓ Environment check prevents production creation

### Files Modified
- `priv/repo/seeds.exs` - Admin user creation logic
- `README.md` - Authentication documentation

All acceptance criteria met and verified.
<!-- SECTION:NOTES:END -->
