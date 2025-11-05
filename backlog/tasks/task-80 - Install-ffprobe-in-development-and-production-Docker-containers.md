---
id: task-80
title: Install ffprobe in development and production Docker containers
status: Done
assignee: []
created_date: '2025-11-05 18:35'
updated_date: '2025-11-05 18:43'
labels: []
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add ffprobe installation to both the development and production Dockerfiles to enable media file metadata extraction and analysis capabilities. ffprobe is part of the FFmpeg suite and is required for analyzing video/audio files in the media library.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 ffprobe is installed in the development Docker container (Dockerfile.dev or similar)
- [x] #2 ffprobe is installed in the production Docker container (Dockerfile or similar)
- [x] #3 ffprobe is accessible from the application runtime environment
- [x] #4 The installation uses minimal image size impact (e.g., ffmpeg-free or ffprobe-only package if available)
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Successfully installed ffmpeg (which includes ffprobe) in both Docker containers:

**Development (Dockerfile.dev):**
- Added `ffmpeg` to the apt-get install list
- Uses Debian packages from the official repositories
- Tested version: ffprobe 5.1.7

**Production (Dockerfile):**
- Added `ffmpeg` to the Alpine apk packages in the runtime stage
- Uses Alpine Linux packages for minimal image size impact
- Tested version: ffprobe 6.1.2

Both installations include the full ffmpeg suite with minimal overhead, as the packages are already optimized for their respective distributions. The runtime containers have ffprobe accessible at `/usr/bin/ffprobe` and can be used by the application for media file analysis.
<!-- SECTION:NOTES:END -->
