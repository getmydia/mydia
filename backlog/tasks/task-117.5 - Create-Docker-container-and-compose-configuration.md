---
id: task-117.5
title: Create Docker container and compose configuration
status: Done
assignee: []
created_date: '2025-11-08 03:05'
updated_date: '2025-11-08 03:48'
labels: []
dependencies: []
parent_task_id: task-117
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Containerize the metadata relay service with Docker using Elixir releases. Create multi-stage build for optimization and docker-compose configuration for local development.

Use mix release for production builds to create a self-contained deployment artifact. Ensure the container is production-ready with proper health checks, signal handling, and security best practices.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Dockerfile uses multi-stage build (build stage + minimal runtime)
- [x] #2 Build stage compiles release with mix release
- [x] #3 Runtime stage uses minimal Alpine image with Elixir runtime only
- [x] #4 Docker image builds successfully and runs the service
- [x] #5 docker-compose.yml includes relay service configuration
- [x] #6 Health check endpoint configured in Docker
- [x] #7 Environment variables properly passed to container

- [x] #8 Container runs as non-root user for security
- [x] #9 Service accessible from host when running in Docker
<!-- AC:END -->
