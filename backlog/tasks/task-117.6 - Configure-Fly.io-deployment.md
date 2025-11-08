---
id: task-117.6
title: Configure Fly.io deployment
status: Done
assignee: []
created_date: '2025-11-08 03:05'
updated_date: '2025-11-08 03:55'
labels: []
dependencies: []
parent_task_id: task-117
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Set up Fly.io deployment configuration for the Elixir metadata relay service. Deploy using Elixir releases and configure secrets management for API keys.

Configure scaling, health checks, and monitoring. The service will be deployed as a standalone Elixir application using Fly.io's Elixir/Phoenix deployment workflow.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 fly.toml configuration created with appropriate resource limits (256MB RAM recommended)
- [ ] #2 Fly.io app created and deployed successfully using fly deploy
- [ ] #3 Secrets configured via fly secrets set for TMDB_API_KEY and TVDB credentials
- [ ] #4 Health checks configured in fly.toml pointing to /health endpoint
- [ ] #5 Release configuration in config/runtime.exs reads environment variables
- [ ] #6 Custom domain or fly.dev subdomain accessible
- [ ] #7 Service responds to requests from public internet

- [ ] #8 Deployment process documented for future updates
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Configuration files created:
- Created fly.toml with 256MB RAM configuration and health checks
- Updated README.md with comprehensive deployment documentation
- Created .dockerignore for optimized builds

Still TODO:
- Actually deploy to Fly.io using `fly launch`
- Set secrets (TMDB_API_KEY, TVDB_API_KEY)
- Verify deployment is accessible
- Test health endpoint

Successfully deployed to Fly.io:
- App URL: https://metadata-relay.fly.dev
- Health check verified: OK
- TMDB endpoints tested and working
- Two machines running with auto-suspend enabled
- API keys configured as secrets
- IPv6: 2a09:8280:1::ad:c20d:0
- IPv4: 66.241.125.34
<!-- SECTION:NOTES:END -->
