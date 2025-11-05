---
id: task-56.1
title: Adopt LinuxServer.io Docker image standards and conventions
status: Done
assignee: []
created_date: '2025-11-05 02:38'
updated_date: '2025-11-05 19:14'
labels:
  - docker
  - deployment
  - documentation
  - standards
dependencies:
  - task-56
parent_task_id: task-56
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Update the Docker image and deployment documentation to follow LinuxServer.io standards, which are widely adopted in the self-hosting community. This includes using PUID/PGID for user mapping, consistent volume paths, standardized environment variable naming, health checks, and following their documentation conventions. LinuxServer.io images are known for excellent documentation and user-friendly deployment patterns.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 PUID and PGID environment variables implemented for user/group mapping
- [x] #2 Volume paths follow LinuxServer.io conventions (/config, /data, etc.)
- [x] #3 Environment variables use LinuxServer.io naming patterns (e.g., TZ for timezone)
- [x] #4 Docker image includes health check configuration
- [x] #5 README.md documentation follows LinuxServer.io format and style
- [x] #6 Image includes standard LinuxServer.io init system patterns if beneficial
- [x] #7 Configuration files are stored in /config volume following LSIO conventions
- [x] #8 Logs are properly directed and accessible via standard paths
- [x] #9 Image metadata (labels) follows LinuxServer.io standards
- [x] #10 Documentation includes parameters table matching LSIO format
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Summary

Successfully adopted LinuxServer.io Docker image standards and conventions for Mydia. All acceptance criteria have been completed.

### Changes Made

**1. Dockerfile Updates:**
- Added PUID/PGID environment variable support (default: 1000)
- Installed necessary packages: su-exec, tzdata, shadow
- Added TZ timezone support (default: UTC)
- Created production entrypoint script (docker-entrypoint-prod.sh)
- Added LSIO-style OCI labels for image metadata
- Updated volume structure: /config for app data, /data and /media for media files
- Changed DATABASE_PATH default from /data/mydia.db to /config/mydia.db
- Added VOLUME declarations for /config, /data, /media

**2. Entrypoint Script (docker-entrypoint-prod.sh):**
- Implements PUID/PGID user mapping using usermod/groupmod
- Sets timezone based on TZ environment variable
- Creates necessary directories with correct ownership
- Displays startup banner with configuration info
- Uses su-exec to drop privileges and run app as specified user

**3. Documentation Updates:**
- README.md restructured to follow LSIO format with:
  - Supported Architectures section
  - Application Setup section
  - Usage section (docker-compose and CLI examples)
  - Parameters tables (ports, environment, volumes)
  - User/Group Identifiers explanation section
  - Updating the Container section
- DEPLOYMENT.md updated with LSIO conventions
- .env.example updated with PUID/PGID/TZ variables
- All configuration examples updated to use /config for database

**4. Codebase Updates:**
- Updated all references from /data/mydia.db to /config/mydia.db across:
  - Configuration files (config.example.yaml, config/config.example.yml)
  - Documentation files (HOOKS_*.md, docs/**/*.md)
  - Example files (.env.example, .env.prod.test)
  - Source code comments (lib/mydia/hooks.ex)

**5. Testing:**
- Built and tested Docker image successfully
- Verified PUID/PGID mapping works correctly (tested with PUID=1001/PGID=1001)
- Verified default values work (PUID=1000/PGID=1000/TZ=UTC)
- Confirmed directory ownership is correctly set
- Verified timezone setting functionality

### LinuxServer.io Standards Adopted

✅ PUID/PGID environment variables for user/group mapping
✅ Volume paths follow LSIO conventions (/config for app data)
✅ TZ environment variable for timezone configuration
✅ Health check configuration (already existed, now documented)
✅ Documentation follows LSIO format and style
✅ LSIO-compatible entrypoint with proper user switching
✅ Configuration files in /config volume
✅ Proper logging to stdout/stderr
✅ OCI-compliant image labels
✅ Comprehensive parameters table in documentation

### Benefits

- **Permission Management**: Users can now map container files to their host user, preventing permission issues
- **Timezone Control**: Proper timezone handling for logs and scheduled tasks
- **Community Standards**: Follows familiar patterns used by hundreds of popular self-hosted applications
- **Better Documentation**: Clear, structured documentation matching community expectations
- **Ease of Use**: Simplified deployment with sensible defaults
<!-- SECTION:NOTES:END -->
