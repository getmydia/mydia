# UI-driven built-in torrent client and VPN

Status: approved design, 2026-11-12. Builds on
`design/specs/2026-11-04-builtin-torrent-vpn-design.md`, which shipped in #1345.

## Goal

An operator with a plain compose file manages the built-in torrent client and
its VPN entirely from Admin, Download Clients: turn the client on or off, set
its paths and ports, pick any gluetun provider, enter credentials, choose a
server location and port forwarding. Changes apply without restarting the
container. Environment variables keep working and override the UI, shown
read-only with an ENV badge, as every other layered setting does. The one
thing the UI cannot do is grant the container `NET_ADMIN` and `/dev/net/tun`;
it shows the compose snippet that does.

## Where Mydia stands

- `BuiltIn.Supervisor.init/1` reads `System.get_env/0` once at boot through
  `BuiltIn.Config.load/3`. Nothing about the built-in client can change while
  Mydia runs.
- `docker/vpn-preflight.sh` runs as root from the entrypoint. It starts
  gluetun in a restart loop only when `MYDIA_VPN_SERVICE_PROVIDER` is set, and
  writes the preflight file only in that case. The BEAM then drops to `mydia`
  with no capabilities.
- The control server's default role is `{"auth":"apikey","apikey":...}` with
  no route list, so the key the BEAM reads from `/config/gluetun/apikey` can
  call every route, including `PUT /v1/vpn/settings`. That route accepts
  OpenVPN settings such as a custom config file and process user, which
  OpenVPN acts on as root. A compromised BEAM can therefore run code as root
  today.
- `Mydia.Config.Loader.reload/0` refreshes the cached runtime config but
  broadcasts nothing.
- Download-client passwords are stored in the database.

## Decisions and why

- **Layered config, applied live.** The yaml, db, env overlay with source
  badges is how Mydia is configured everywhere; this feature joins it rather
  than adding a UI-only store or keeping env-only fields.
- **Every gluetun provider, one generic form.** A small provider table in
  Mydia drives which fields show. No free-form gluetun variables in the UI:
  each one would need its own safety review, and env already covers the long
  tail.
- **Desired-state file plus a root watcher, not gluetun's settings API.**
  Mydia writes the UI's VPN settings to a file; the root loop filters them
  through an allowlist and restarts gluetun when the file changes. One path
  serves first start and every edit, and it does not couple Mydia to
  gluetun's internal settings JSON, which changes between releases. Rejected:
  starting from the file and editing through `PUT /v1/vpn/settings` (two
  paths, the JSON coupling, and the allowlist needed twice); a privileged
  helper daemon with a typed socket API (a new binary to build and ship for
  what the shell loop already does).
- **Lock the control server to read routes.** With the file as the only way
  to change settings, the BEAM's key needs nothing else. This closes the
  existing escalation path.
- **The kill switch stays strict on every change.** Any settings change goes
  through the same gate as boot: VPN connecting, engine stopped, leak check,
  engine start.

## Configuration

A new top-level `built_in_torrent` section in `Mydia.Config.Schema`, resolved
by `Mydia.Config.Loader` like every other section (yaml, then db, then env;
env wins). Source badges come from `Mydia.Settings.config_source/3`. The
section is flat, with `vpn_` prefixes rather than a nested `vpn` embed,
because `Mydia.Config.Schema.Paths` indexes database overlay keys one level
deep (`section.field`); a nested embed could not be set from the database.

| Field | Env variable | Default |
| --- | --- | --- |
| `enabled` (nil, true, false) | `MYDIA_TORRENT_ENABLED` | nil |
| `download_path` | `MYDIA_TORRENT_DOWNLOAD_PATH` | `/data/downloads` |
| `state_path` | `MYDIA_TORRENT_STATE_PATH` | `/config/rqbit` |
| `listen_port` | `MYDIA_TORRENT_PORT` | `51413` |
| `api_port` | `MYDIA_TORRENT_API_PORT` | `3030` |
| `vpn_enabled` | implied by `MYDIA_VPN_SERVICE_PROVIDER` being set | false |
| `vpn_provider` | `MYDIA_VPN_SERVICE_PROVIDER` | nil |
| `vpn_type` (openvpn, wireguard) | `MYDIA_VPN_VPN_TYPE` | provider's first supported type |
| `vpn_openvpn_user` | `MYDIA_VPN_OPENVPN_USER` | nil |
| `vpn_openvpn_password` | `MYDIA_VPN_OPENVPN_PASSWORD` | nil |
| `vpn_wireguard_private_key` | `MYDIA_VPN_WIREGUARD_PRIVATE_KEY` | nil |
| `vpn_wireguard_addresses` | `MYDIA_VPN_WIREGUARD_ADDRESSES` | nil |
| `vpn_server_countries` | `MYDIA_VPN_SERVER_COUNTRIES` | nil |
| `vpn_server_regions` | `MYDIA_VPN_SERVER_REGIONS` | nil |
| `vpn_server_cities` | `MYDIA_VPN_SERVER_CITIES` | nil |
| `vpn_server_hostnames` | `MYDIA_VPN_SERVER_HOSTNAMES` | nil |
| `vpn_port_forwarding` | `MYDIA_VPN_VPN_PORT_FORWARDING` | false |

- `enabled: nil` keeps the automatic rule from the 2026-11-04 spec: on when
  `rqbit` is on the `PATH` and no torrent-capable client is configured. The
  marker-file stickiness applies to this case only; an explicit db or env
  value always beats it.
- `vpn_enabled` is its own field, so a user can fill in the form and switch it
  on afterwards. From env it is implied by a non-blank
  `MYDIA_VPN_SERVICE_PROVIDER`, as today.
- `vpn_provider` and `vpn_type` are strings in the schema, trimmed and
  downcased, never atoms. They are validated against `VpnProviders` by the
  form at save time, not by the schema: an env value naming a provider newer
  than the table must not fail the whole config load, and gluetun reports a
  bad one itself.
- `MYDIA_VPN_*` variables outside this table still reach gluetun from env
  through the root loop, unchanged. The panel lists their names, never their
  values, under "Also set from environment".
- **`BuiltIn.VpnProviders`** lists every gluetun provider in the pinned
  release with its supported VPN types and whether it forwards ports. It
  drives the form and validation. A test fails when `vendor/gluetun/VERSION`
  changes without the table's recorded version changing with it.
- **Secrets.** `vpn_openvpn_password` and `vpn_wireguard_private_key` are stored in
  the database the way download-client passwords are, never rendered back to
  the browser, never logged, and redacted wherever download-client passwords
  are redacted (config export, crash reports).

## Applying changes

### Change signal

`Mydia.Config.Loader.reload/1` broadcasts `{:runtime_config_reloaded,
config}` on the `"config:runtime"` PubSub topic after it stores a new runtime
config. Every save path already ends in `reload/1`, so one broadcast there
covers them all. It is general; this feature is its first subscriber.

### Engine

`BuiltIn.Manager` replaces the decision logic in `BuiltIn.Supervisor.init/1`.
It builds `BuiltIn.Config` from the runtime config rather than
`System.get_env/0`, subscribes to `"config:runtime"`, and on each message
compares the new effective config with the running one. Only a difference
restarts anything: it stops the running `BuiltIn.Supervisor` tree under a
`DynamicSupervisor`, replaces the `Runtime` entry, and starts a new tree. A
save that does not change the effective built-in config restarts nothing.

- rqbit persists its session, so torrents resume after a restart.
- A new download path applies to new grabs. Torrents already in the session
  finish in their original folder; the form says so next to the field.
- Disabling the client while downloads are active asks for confirmation and
  names how many.

### VPN, Mydia side

The form validates the VPN fields against `VpnProviders` at save time. Each
time `Manager` applies a config, `BuiltIn.VpnSettings` writes
`/config/gluetun/settings.env` atomically (write a temp file, rename), mode
600, owned by `mydia`, and only when its content changed. The file holds
`VPN_ENABLED` plus the allowlisted gluetun keys whose value does not come
from env (env values reach gluetun from the root's own environment, so they
are never copied to disk), one `KEY=value` per line. Values containing a
newline are rejected at save. The root loop reads each value back as a single
argument, with no shell evaluation.

`Vpn` runs while the VPN is enabled. It learns the SHA-256 of the file
`Manager` wrote and stays `connecting`, with the engine stopped, until
`loop-status` reports that hash applied. This keeps a gluetun still running
the previous settings from passing the leak check. Then it waits for gluetun
to report running, runs `LeakCheck`, and lets the engine start.

Turning the VPN off while the engine runs asks for confirmation ("torrents
will use this server's real IP"). After that the engine restarts without
`--bind-device`.

### VPN, root side

`vpn-preflight.sh` changes:

- It always writes the preflight file, unless `MYDIA_TORRENT_ENABLED` turns
  the client off in env.
- When the capabilities and split group are present, it always generates the
  API key and starts the supervisor loop. The loop idles while neither the
  settings file (`VPN_ENABLED=true`) nor env (`MYDIA_VPN_SERVICE_PROVIDER`)
  enables the VPN.
- Every 2 seconds the loop hashes the settings file. On a change, or on
  gluetun exiting, it stops gluetun if running and starts it with, in order:
  1. keys from the file that are in a fixed allowlist in the script (the
     table's keys above, prefix stripped); any other key is dropped and named
     in the loop's status file;
  2. the operator's `MYDIA_VPN_*` env, prefix stripped, so env wins;
  3. Mydia's own variables last, as today.
- After each start the loop writes `/config/gluetun/loop-status` with the
  applied file hash and any dropped keys, readable by `mydia`.
- The control server is locked to three routes: `GET /v1/vpn/status`,
  `GET /v1/publicip/ip`, `GET /v1/portforward`. Gluetun ignores `routes` in
  `HTTP_CONTROL_SERVER_AUTH_DEFAULT_ROLE` (the default role covers every route
  no other role names), so the script instead writes a root-owned TOML file,
  `/config/gluetun/auth.toml`, with one apikey role listing those routes, and
  passes `HTTP_CONTROL_SERVER_AUTH_CONFIG_FILEPATH` with an empty default
  role. A route no role lists is refused. The BEAM's key can no longer change
  settings or status through the API.

### Missing capabilities

`NET_ADMIN`, `/dev/net/tun` and the `src_valid_mark` sysctl need the
container recreated. When the preflight file reports any of them missing, the
VPN section stays visible with its toggle disabled, behind a setup card that
shows the exact compose lines (`cap_add`, `devices`, `sysctls`).

## UI

Admin, Download Clients, built-in panel.

- **Panel.** The status card stays and gains a **Configure** button. When the
  client is off it still renders, compactly: "Off", the reason (automatic
  rule, env, or set in the UI), and an **Enable** action, so a user who runs
  an external client can find it.
- **Modal**, a page-level `<dialog class="modal">` per
  `lib/mydia_web/components/README.md`, with two sections switched by
  `<.segmented_control>`:
  - **Torrent:** enabled (Automatic, On, Off), download path, listen port, and
    an Advanced collapse with state path and API port.
  - **VPN:** enable toggle; provider select over `VpnProviders`; VPN type as a
    segmented control, shown only when the provider supports both; the
    credential fields for that type; server countries, regions, cities and
    hostnames as comma-separated text; port forwarding, shown only when the
    provider forwards ports; the "Also set from environment" list.
- Every field carries the ENV, DB or Default badge. ENV fields are read-only,
  with a tooltip naming the variable. Secret fields show "Saved" with a
  Replace button; their values are never sent to the browser.
- **Save.** `phx-change` validates against `VpnProviders` (for example,
  WireGuard on a provider without it is an inline error). After save the modal
  closes and the panel shows progress from the existing `Status` broadcasts:
  applying, connecting, leak check, running on port N. A failure appears as a
  typed reason with fix text.
- There is no connection test button. Only bringing the tunnel up proves the
  settings, and the save flow already shows that.
- Markup stays in `admin_download_clients_live/built_in_components.ex`, with
  the form split into a sibling `built_in_form_components.ex` to keep each
  under about 500 lines. `index.ex` calls a context function,
  `BuiltIn.Settings.save/1`; no business logic sits in the LiveView.

## Errors

New reasons travel the existing path: the panel, `ClientHealth`, the
adapter's `{:error, reason}`, and an `error` log on each transition.

| Reason | Shown as |
| --- | --- |
| `{:vpn_settings_write_failed, posix}` | Could not write `/config/gluetun/settings.env`; the VPN keeps its previous settings |
| `{:vpn_settings_rejected, keys}` | The root loop dropped keys outside its allowlist; a version mismatch between Mydia and the image's script, named by key |
| `:vpn_apply_timeout` | Gluetun did not pick up the new settings within 30 seconds (the hash in `loop-status` differs from the one written) |
| `{:invalid_vpn_settings, field, message}` | A form error at save time, never a runtime state |

Existing reasons (`:missing_net_admin`, `:missing_tun`, `:vpn_down`,
`:leak_detected`, `{:port_forward_failed, msg}`, `{:engine_exit, code}`) are
unchanged. `{:reserved_variable, name}` still applies to env.

## Testing

- **Unit:** Loader env-to-field mapping and precedence for every field in the
  table; `vpn_provider` and `vpn_type` normalized to lowercase strings;
  `VpnProviders` pinned to `vendor/gluetun/VERSION`; `VpnSettings`
  validation and atomic write; `Manager` restarting on an effective change and
  not on an unrelated save, against the fake `rqbit` script; `Vpn` closing the
  engine gate and rerunning the leak check on a settings change; secret
  redaction.
- **Shell** (`vpn_preflight_script_test.exs`): allowlist filtering and the
  dropped-keys status line, env over file, idle until enabled, restart on a
  hash change, the route-restricted role string.
- **LiveView:** ENV fields read-only, secret values absent from rendered HTML,
  provider switch showing and hiding fields, both confirmations, the setup
  card when capabilities are missing, the off-state panel with Enable.
- **Browser:** the modal measured at phone width.
- **Manual Docker smoke**, added to `vendor/gluetun/README.md`: start with no
  VPN env, enable ProtonVPN from the UI, confirm the torrent group's public IP
  is the VPN's and Mydia's is the host's, change the server country, confirm
  the reconnect and that torrents resume.

## Docs

`docs/using/reference/download-clients.md` leads with the UI flow.
`docs/using/reference/environment-variables.md` describes the variables as
overrides of UI settings.

## Out of scope

Server location dropdowns built from gluetun's bundled server list (free text
for now), more than one built-in engine, VPN support in the NixOS module, and
free-form gluetun variables in the UI.
