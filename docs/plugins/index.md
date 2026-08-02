# Building Plugins

This section is for developers building Mydia plugins. If you just want to use a
plugin someone else wrote, install and configure it from the admin UI; you do
not need any of this.

Mydia plugins are small, sandboxed programs that react to what happens in your
library. When a movie is added, a download completes, a file is imported, or
someone finishes watching something, Mydia hands the event to your plugin and
lets it do something useful: post a notification, call an external API, enrich
the event with library data. Plugins can also run on a fixed schedule, keep a
little durable state, link a per-user third-party account, and sync watched
state both ways. The bundled Simkl plugin does all of this.

A plugin is a WebAssembly **component** written in Rust against the published
`mydia-plugin-sdk` crate. You write one typed handler function; the SDK turns it
into a component the host can load. The plugin runs in a sandbox with no ambient
network, filesystem, or OS access. The only way out is through a small set of
capability-gated host functions you declare up front, approved by the operator
before the plugin ever runs.

## Where to start

<div class="grid cards" markdown>

-   **New to plugins**

    Follow the [tutorial](tutorial/write-your-first-plugin.md) and have a
    working plugin logging on `media_item.added` in about 10 minutes.

-   **Have a specific task**

    The how-to guides cover [sending notifications](how-to/notifications.md),
    [reading media and event data](how-to/media-data.md),
    [building a two-way sync](how-to/two-way-sync.md), and the
    [test and reload loop](how-to/test-and-iterate.md).

-   **Need the contract**

    The [host API reference](reference/host-api.md) is the event catalog,
    capability classes, and host functions. The
    [manifest schema](reference/manifest.md) covers every manifest field.

-   **Want to know why**

    [The plugin model](explanation/plugin-model.md) explains the sandbox, the
    capability system, and what the host-version floor is for, including its
    current limitations.

</div>
