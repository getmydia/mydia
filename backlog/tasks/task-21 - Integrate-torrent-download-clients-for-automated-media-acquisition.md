---
id: task-21
title: Integrate torrent download clients for automated media acquisition
status: Done
assignee: []
created_date: '2025-11-04 03:32'
updated_date: '2025-11-04 19:19'
labels:
  - automation
  - downloads
  - integration
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Enable Mydia to integrate with popular torrent download clients (qBittorrent, Transmission) to automate media acquisition. This feature allows users to configure download clients, submit torrents for download, monitor download progress, and automatically import completed media files into the library.

This is a foundational automation feature required for Phase 2 of the roadmap. The implementation should follow the External Service Adapters pattern shown in the technical architecture, with a pluggable adapter system that makes it easy to add support for additional download clients in the future.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Users can configure one or more download clients via YAML configuration or environment variables
- [x] #2 System can submit torrent files or magnet links to configured download clients
- [x] #3 Download progress is tracked and displayed in the downloads queue UI
- [x] #4 Completed downloads are automatically detected and imported into the media library
- [x] #5 Download client health status is monitored and reported
- [x] #6 Multiple download clients can be configured and used simultaneously
- [x] #7 Failed downloads are detected and reported with appropriate error messages
<!-- AC:END -->
