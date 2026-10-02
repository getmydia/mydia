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
canonical WIT contract `mydia:plugin@1.5.0`, living at
`native/mydia_plugin_sdk/wit/plugin.wit`.

It **exports** `handler.on-event`, called for each event it subscribed to,
`handler.on-schedule`, called on a fixed interval, and, from 1.5,
`handler.setup`, which drives the setup wizard the host renders, and
`handler.check-health`, which the host calls to show an instance's health. A
plugin that serves its own pages also exports `page.on-http` (from 1.4). The
SDK macro generates all of these exports, and one a plugin does not implement
returns an error. It
**imports** the host's capabilities: `http-request`, `data-read` and `log`
from 1.0; the key-value store, `data-list`, watch-state writes and
per-user connections from 1.1 to 1.3; the page functions from 1.4; and account
links, store listing and batch writes, and sync-run reports from 1.5. Every import is enforced
server-side on every call; there is no path around it.

The package version in the WIT file **is** the ABI version, and the contract
is meant to evolve additively (new functions, new record fields, new variant
cases) rather than by breaking existing signatures. That's what lets a plugin
built against `1.0` keep running unmodified against a `1.5` host: the host
detects the guest's contract version from its bytes at instantiation and
serves the matching interface, rather than forcing every plugin to track the
host's latest release.

## What the host owns and what a plugin owns

Every plugin, bundled or third-party, follows one rule: **the host owns the
nouns other features need to see, and the plugin owns the behaviour specific to
the remote system.**

Two questions place any piece of a design:

- *Would the admin UI, a user's profile page, another feature, or a different
  plugin ever need to read or show this?* If so, it is a host noun. The plugin
  reads and writes it through contract functions, and the host stores it.
- *Does it change when the remote service changes its API?* If so, it belongs
  to the plugin.

**Host nouns** are watch state, favorites, which Mydia user is linked to which
remote account, per-user connections and their tokens, operator settings and
secrets, plugin instances, sync-run history, health status, schedules, egress
policy, and shelves. For a shelf, the list, its staleness and its dismissals are
the host's; choosing the titles is the plugin's. The host also renders every
screen. A plugin describes setup steps declaratively and ships no UI code of
its own.

**Plugin behaviour** is the protocol: auth handshakes, server discovery and
endpoint probing, pagination, parsing remote IDs, crawling the remote library
to build mappings, and the reconcile loop that decides what to pull and push.
The plugin's working state (checkpoints, cursors, mapping caches) lives in its
own store and is opaque to the host.

Three consequences follow:

- **A plugin never keeps the only copy of a host noun.** Storing account links
  or sync history in KV because the contract lacks a function for it is a
  violation. Add the noun to the host instead.
- **New host nouns are generic.** A noun is named for the concept ("account
  link", "sync run"), never for the service ("Plex profile"), and needs a
  plausible second consumer before it enters the contract.
- **Shared engines are optional helpers.** A Rust crate that packages
  reconciliation or polling logic is welcome, but the contract must never
  require it. A plugin written in another language, or one that needs a
  different loop, still gets every host noun.

A plugin can run as several **instances**, one per configured server or
account, when its manifest sets `multi_instance`. Each instance has its own
settings, store, account links, schedule and sync history, and the plugin
learns which instance it is serving from `instance_id` in its injected config.

The rule sits between two common designs. Typed-slot systems (Terraform
providers, Kodi PVR add-ons, Grafana data sources) keep the engine in the host
and leave the plugin a thin adapter. That duplicates nothing, but the engine
can never leave core and plugins cannot do what the slot did not anticipate.
Fully self-contained systems (Jellyfin's Trakt plugin, Obsidian, WordPress)
hand the plugin everything, including UI and storage. That gives authors full
freedom, but the host cannot explain what a plugin did and every plugin invents
its own UX. Home Assistant's integrations are the closest model to Mydia's:
self-contained code that plugs into host-owned entities and host-rendered
config flows.

## The capability-based sandbox

Every class of thing a plugin might want to do (make an HTTP request, read a
media record, hold a key/value store, run on a schedule) is a named
**capability**, and capabilities are deny-by-default. A plugin's manifest
*declares* what it wants; for a third-party plugin the operator sees that
declaration and approves it before the plugin runs at all. A plugin can never
widen its own grant at runtime; there's no equivalent of asking for permission
mid-execution the way a mobile app might.

Third-party plugin grants never auto-expand. A plugin installed from an index or
remote package runs only with the capability set an administrator approved, and
a revised manifest that asks for more remains on its old grant until explicit
re-approval.

Image-bundled system plugins are the deliberate exception. They are delivered as
part of the trusted Mydia host release, so discovery grants their complete
shipped capability set and enables a new system plugin. Later host upgrades
replace that grant with the bundled manifest's current effective set, including
settings-derived HTTP hosts. Upgrades preserve whether the administrator has
since enabled or disabled the plugin.

What both cases share is the guarantee worth trusting: what a plugin may do is
fixed in the `granted_capabilities` the host stores, and the host re-checks that
grant on every call rather than trusting the manifest.

It's worth being precise about what third-party grants not auto-expanding does
**not** mean. Revising a third-party manifest to declare a new capability class,
a new `net:http` host, or a new subscribed event does not return the plugin to
unapproved, and it does not grant the new capability either. The stored grant is
left exactly as it was, and the plugin keeps running on it. Calls against
anything newly declared come back `Denied` until an operator re-approves.

What changed is that this is no longer silent. Mydia compares each installed
plugin's declared capabilities against its grant, value by value, so a new host
in an allowlist or a new event in `events:subscribe` counts just as much as a
whole new class. A plugin whose manifest has outgrown its grant is badged
**needs re-approval** in Admin > System > Plugins, its row names what it is asking
for beyond what you approved, and its **Review & re-approve** button opens the
same approval modal with the new capabilities called out separately from the
rest. Re-approving grants the currently requested set. The host also logs a
warning naming the ungranted capabilities whenever such a plugin starts, so
non-bundled capability drift is visible in the server log as well as in the UI.

For a third-party plugin, nothing about the safety property moved: the grant
still only widens when an operator approves it, saving unrelated plugin settings
will not pull newly declared hosts into the allowlist, and until you re-approve,
the plugin runs on exactly what it had. A bundled system plugin is trusted
differently on purpose: its grant tracks the manifest in the host release the
administrator chose to run, and enabling or disabling it stays their decision.

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

## Pages and writes on a user's behalf

Most plugins react to events with no user in the room. A plugin that declares
`surfaces:page` is different: it serves its own page inside Mydia, and what it
does there it does for the person looking at it. The model that keeps this safe
has a few parts.

**Interaction scope.** Page host functions (`search`, `media-add`, the
`collection-*` writes, `mark-watched-state`, `add-favorite`) work only during an
`on-http` call, and only as the user of that call. The host takes the user, role
and page session from a signed token and the database, never from the request
body or the guest, and refuses the same functions from an event or schedule
handler. Reads in a page call are scoped to that user too, so a page never sees
more than the person using it.

**The frame token.** The page authenticates with a signed token that is a
one-hour bearer. A password change invalidates it at once, but logging out does
not revoke it.

**Grants.** A write surface the plugin declares in `surfaces:write` is still not
enough on its own. The first time a page writes to a surface for a user, the
write is parked and the user is asked. They can answer **once** (this write
only), **for this session** (until the page is closed or reloaded) or **always**
(until revoked). Later writes to that surface by that plugin for that user then
go through without a prompt.

**Role ceilings.** An administrator caps the longest grant each role may hold
per plugin, in the plugin's settings. The defaults are `always` for admins and
users, `session` for guests and `none` for read-only users. A user is only
offered choices at or below their role's ceiling, and lowering a ceiling stops
counting stored grants above it at once. Role also decides what a write means:
a guest's `media-add` files a request, a user's adds to the library.

**A confirmation the plugin cannot fake.** The page runs in a sandboxed iframe
and can only ask, by posting `{mydia: "confirm", ids}` to its parent. The host
then shows its own modal, built from the pending-write rows it stored (what will
change, resolved by the host), not from anything the plugin sent. The allow or
deny decision comes from a click in the host's UI, and the plugin only hears
back `confirmed`, `denied` or `expired`. A pending write expires after an hour.

**Journal and undo.** Every write that happens is recorded in a journal, and
the write and its entry commit together, so nothing changes unrecorded. Most
entries carry the inverse needed to revert them; one the host cannot reverse is
shown as irreversible. Users see their entries on `/plugins/<slug>/activity` and
can undo one entry or a whole batch. Undo refuses when the item has changed
since, and cannot be applied twice.

**Why the host never sees page content.** The host is a courier for page
traffic. Request and response bodies pass through to and from the guest as
opaque text; the host does not parse, store or log them, and no host code knows
what a page is for. The only data the host keeps is what it resolved itself: the
pending-write rows and the journal, which hold host-resolved arguments (ids,
titles it looked up) and never the page's own content. Whatever the page keeps
stays in the plugin's own per-user `state:kv` keys.

To build one, see [Serve a page](../how-to/pages.md).

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
