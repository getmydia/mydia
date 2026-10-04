# Building Plugins

This section is for developers building Mydia plugins. If you just want to use a
plugin someone else wrote, [install and configure it](../using/how-to/plugins.md) as an
operator; you do not need any of this.

Mydia plugins are small, sandboxed programs that react to what happens in your
library. When a movie is added, a download completes, a file is imported, or
someone finishes watching something, Mydia hands the event to your plugin and
lets it do something useful: post a notification, call an external API, enrich
the event with library data. Plugins can also run on a fixed schedule, keep a
little durable state, link a per-user third-party account, and sync watched
state both ways. The bundled Simkl plugin does all of this.

A plugin is a WebAssembly **component** written in Rust against the
`mydia-plugin-sdk` crate. You write one typed handler function; the SDK turns it
into a component the host can load. The plugin runs in a sandbox with no ambient
network, filesystem, or OS access. The only way out is through a small set of
capability-gated host functions you declare up front. Operators approve what a
third-party plugin may do before it runs, while plugins bundled with Mydia get
their declared permissions on discovery; [the plugin model](explanation/plugin-model.md)
explains the trust rules.

## Where to start

<div class="grid cards" markdown>

-   **New to plugins**

    Follow the [tutorial](tutorial/write-your-first-plugin.md) and have a
    working plugin logging on `media_item.added` in about 10 minutes.

-   **Have a specific task**

    The how-to guides cover [sending notifications](how-to/notifications.md),
    [reading media and event data](how-to/media-data.md),
    [building a two-way sync](how-to/two-way-sync.md),
    [custom pages](how-to/pages.md), [home shelves](how-to/shelves.md), a
    [setup wizard](how-to/setup-wizard.md), and the
    [test and iterate loop](how-to/test-and-iterate.md). To distribute plugins
    yourself, see [publishing your own plugin source](how-to/publish-a-source.md).

-   **Need the contract**

    The [manifest](reference/manifest.md), [events](reference/events.md),
    [capabilities](reference/capabilities.md),
    [host functions](reference/host-functions.md),
    [guest exports](reference/guest-exports.md), [limits](reference/limits.md)
    and [plugin source format](reference/plugin-source-format.md) pages cover
    the runtime contract.

-   **Want to know why**

    [The plugin model](explanation/plugin-model.md) explains the sandbox, the
    capability system, and what the host-version floor is for, including its
    current limitations.

</div>
