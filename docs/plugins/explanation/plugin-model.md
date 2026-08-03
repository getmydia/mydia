# The Plugin Model

This page explains why Mydia plugins are shaped the way they are: why a Wasm
component instead of an embedded scripting language, how the capability
sandbox works, what its current limits actually are, and what the
host-version floor buys an operator running a self-hosted instance. For the
mechanical contract (the event schema, the capability table, the manifest
fields), see the [reference](../reference/host-api.md) and
[manifest schema](../reference/manifest.md). For hands-on steps, see the
[tutorial](../tutorial/write-your-first-plugin.md) and the
[how-to guides](../how-to/notifications.md).

## Why a component, not a scripting runtime

A lot of plugin systems reach for an embedded scripting language: ship a Lua
or JS interpreter in the host process, hand a plugin author a global object,
and let them call whatever the interpreter exposes. That's fast to build and
familiar to write against, but the safety boundary is only as good as what the
embedder remembers to leave out of the global namespace, and every plugin
shares the interpreter's runtime and heap with the host process.

Mydia plugins are **WebAssembly components** instead. A component's imports
and exports are typed and declared up front in a WIT (WebAssembly Interface
Types) file, not discovered by calling into a global object at runtime. That
buys three things a scripting embed doesn't give for free:

- **No ambient anything.** A freshly instantiated component has no network,
  filesystem, or OS access by default. The only functions it can call are the
  ones the host explicitly linked in, one per declared capability. There's no
  equivalent of "someone forgot to strip `os.execute` from the sandbox," since
  nothing is there to strip.
- **A typed, versioned boundary.** The WIT contract, not a hand-rolled JSON
  protocol or a set of blessed global functions, is the single source of
  truth both the Elixir host and the Rust guest SDK build against. wasmtime's
  component linker type-checks the boundary at instantiation and refuses a
  guest whose imports don't match, so drift between host and guest is a build
  error, not a runtime surprise months later.
- **Fresh isolation per call.** Each invocation runs against a fresh component
  instance and store, so guests never share mutable linear memory with each
  other or across calls. A scripting-language plugin system that shares one
  interpreter heap across plugins doesn't get this for free either.

The SDK (`mydia-plugin-sdk`) happens to be Rust today, but nothing
about the contract is Rust-specific: it's a WIT interface, which is the point
of the component model. The `#[mydia_plugin_sdk::plugin]` macro just adapts a
plain typed handler function onto the component's exported interface, so plugin
authors never hand-write the generated binding boilerplate.

## Exports, imports, and the contract version

A plugin is a Wasm **component** built for `wasm32-wasip2` against the
canonical WIT contract `mydia:plugin@1.1.0`, living at
`native/mydia_plugin_sdk/wit/plugin.wit`.

It **exports** `handler.on-event`, called for each event it subscribed to,
and optionally `handler.on-schedule`, called on a fixed interval. It
**imports** the host's capabilities: `http-request`, `data-read`, `log`, plus
the 1.1 additions `kv-get`/`kv-set`/`kv-delete`, `data-list`, `ensure-watched`,
`connections-list`, and `connection-request`. Every import is enforced
server-side on every call; there is no path around it.

The package version in the WIT file **is** the ABI version, and the contract
is meant to evolve additively (new functions, new record fields, new variant
cases) rather than by breaking existing signatures. That's what lets a plugin
built against `1.0` keep running unmodified against a `1.1` host: the host
detects the guest's contract version from its bytes at instantiation and
serves the matching interface, rather than forcing every plugin to track the
host's latest release.

## The capability-based sandbox

Every class of thing a plugin might want to do (make an HTTP request, read a
media record, hold a key/value store, run on a schedule) is a named
**capability**, and capabilities are deny-by-default. A plugin's manifest
*declares* what it wants; the operator sees that declaration and approves it
before the plugin runs at all. A plugin can never widen its own grant at
runtime; there's no equivalent of asking for permission mid-execution the way
a mobile app might.

Grants never auto-expand, and that is the guarantee worth trusting: what an
approved plugin may do is fixed at the moment the operator approved it, in the
`granted_capabilities` the host stores, and the host re-checks that grant on
every call rather than trusting the manifest.

It's worth being precise about what "never auto-expand" does **not** mean.
Revising a manifest to declare a new capability class, a new `net:http` host, or
a new subscribed event does not return the plugin to unapproved, and it does not
grant the new capability either. The stored grant is left exactly as it was, and
the plugin keeps running on it. Calls against anything newly declared come back
`Denied` until an operator re-approves.

What changed is that this is no longer silent. Mydia compares each installed
plugin's declared capabilities against its grant, value by value, so a new host
in an allowlist or a new event in `events:subscribe` counts just as much as a
whole new class. A plugin whose manifest has outgrown its grant is badged
**needs re-approval** in Configuration > Plugins, its row names what it is asking
for beyond what you approved, and its **Review & re-approve** button opens the
same approval modal with the new capabilities called out separately from the
rest. Re-approving grants the currently requested set. The host also logs a
warning naming the ungranted capabilities whenever such a plugin starts, so an
upgrade that widens a bundled manifest is visible in the server log as well as in
the UI.

Nothing about the safety property moved: the grant still only widens when an
operator approves it, saving unrelated plugin settings will not pull newly
declared hosts into the allowlist, and until you re-approve, the plugin runs on
exactly what it had.

This is also why `net:http` is an exact-hostname allowlist with no wildcards:
a wildcard subdomain grant is effectively an open exfiltration channel, since
the plugin author (or someone who compromises their supply chain later)
controls what any subdomain of that wildcard resolves to. The full capability
table and its host functions are in the [reference](../reference/host-api.md);
what matters here is the shape of the guarantee: the host, not the plugin,
decides what "having a capability" actually allows on every single call, not
just the first one.

## Two honest limitations

The sandbox is real, but it isn't complete, and plugin authors will find the
edges eventually, so it's worth stating them plainly rather than letting
someone discover them the hard way:

- **The memory cap only applies at instantiation.** Mydia caps a component
  store's linear memory, but the underlying Wasm runtime only enforces that
  cap when a component is instantiated: an instance whose *minimum* declared
  memory exceeds the cap is refused outright. It does not currently cap
  `memory.grow` calls once the instance is running. A guest that keeps
  allocating at runtime is not stopped by the memory cap alone.
- **There is no fuel or CPU metering for component-model guests.** A runaway
  loop in a handler isn't preemptively interrupted the way it would be under a
  runtime with fuel or epoch-based interruption. What still bounds it is a
  per-call wall-clock timeout that force-kills the invocation and reclaims the
  Elixir process on the other side of the call; the residual is that the
  underlying OS thread of a wedged guest isn't reclaimed until it yields on
  its own.

Both are accepted trade-offs of the current Wasm component runtime, not design
choices Mydia is defending as sufficient on their own. They're one reason
Mydia's plugin model leans on a **curated, trusted set of plugins** rather
than treating the sandbox as the sole safety boundary against an arbitrary,
unvetted one: the capability system and the instantiation-time memory cap are
real, meaningful guards, but they are not a substitute for knowing what a
plugin you install actually does.

## What the host-version floor is for

A plugin's manifest can declare `min_host_version`, the lowest Mydia release
it needs. Because Mydia is self-hosted, there's no coordinated deploy order
between "the host" and "the plugins running on it": an operator upgrades their
instance whenever they choose, and a plugin author has no way to know which
host version any given installation is running. `min_host_version` lets a
plugin that genuinely needs a capability, event, or host function added in a
specific release say so explicitly. Mydia refuses to activate a plugin whose
floor exceeds the running host with a clear "requires mydia >= X" message,
rather than instantiating it anyway and failing in a way that looks like a
mysterious runtime bug. Combined with the additive-evolution rule above, this
is what makes it safe for a `1.0` plugin and a `1.1` plugin to both run
correctly against the same host, and for that host to be upgraded without
breaking either.
