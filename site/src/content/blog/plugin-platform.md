---
title: "Plugins Are Coming to Mydia"
date: 2026-06-09
summary: "Mydia is adding a WebAssembly plugin sandbox with explicit capability permissions, starting with a webhook and Discord notifier."
tags: ["development", "plugins"]
---

Mydia is adding support for WebAssembly plugins. Each plugin runs in a sandbox and can only use the permissions you grant on install. The first built-in plugin sends notifications to Discord or a generic webhook when media is added or a download finishes.

## Why plugins

Until now, every indexer, metadata source, download client, and external integration lived inside the Mydia Server repository. That couples every niche integration to the main release cycle and expands the main codebase for features only some setups use.

Moving integrations into WebAssembly plugins lets third-party extensions run outside the core server while keeping a strict security boundary, similar to how [Zed](https://zed.dev/) isolates editor extensions.

## Capability permissions

Plugins run in a Wasmtime sandbox with no default access to the filesystem, network, or database. Each plugin declares the capabilities it needs in its manifest:

- Events it subscribes to (for example, `media.added` or `download.completed`)
- Outbound HTTP hosts it requests permission to contact (such as `discord.com`)
- Host functions it calls to read library data

When you install a plugin, Mydia Server lists these requested permissions and waits for approval before enabling it. Requests to unapproved hosts or capabilities are rejected at the host boundary, and permissions can be revoked at any time in the admin UI.

HTTP requests from plugins are restricted to the approved host list and blocked from connecting to private, loopback, or link-local IP ranges, preventing plugins from probing services on your local network.

If a plugin traps, exceeds its memory limit, or times out, the failure is isolated to that plugin invocation.

## First plugin: webhook and Discord notifier

To test the runtime end to end, we wrote a notification plugin as the first guest module. When an item is added to a library or a download completes, the plugin posts a formatted message to a configured Discord webhook or generic HTTP endpoint, with retries when the destination returns a transient error.

## Activity log and testing

Each installed plugin has an activity page in the admin UI showing recent invocations, durations, and any error output. A **Test** action lets you send a sample event immediately after configuring a plugin to verify that credentials and network permissions work.

## Next steps

Writing a plugin currently requires implementing the WIT guest interface directly in Rust. We are working on:

- A Rust SDK crate that wraps the guest bindings and event types
- Documentation for building and loading plugins from other languages that target WASIP2
- A plugin catalog for installing community plugins from the admin UI

Feedback and contributions are welcome [on GitHub](https://github.com/getmydia/mydia).
