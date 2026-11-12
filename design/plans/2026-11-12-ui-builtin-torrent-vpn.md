# UI-driven built-in torrent client and VPN Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Manage the built-in torrent client and its VPN from Admin, Download Clients, applied live, with env vars as read-only overrides.

**Architecture:** A flat `built_in_torrent` config section joins the layered Loader. `Loader.reload/1` broadcasts; a new `BuiltIn.Manager` rebuilds `BuiltIn.Config` from the runtime config and restarts the `BuiltIn.Supervisor` tree under a `DynamicSupervisor` only when the effective config changed. VPN settings reach the root-run gluetun through `/config/gluetun/settings.env`, which a root loop in `docker/vpn-preflight.sh` filters by allowlist and applies; `Vpn` gates the engine on the loop confirming that file's hash.

**Tech Stack:** Elixir/Phoenix LiveView, Ecto embedded schemas, POSIX sh (Alpine busybox), gluetun v3.41.3.

**Spec:** `design/specs/2026-11-12-ui-builtin-torrent-vpn-design.md` (builds on `design/specs/2026-11-04-builtin-torrent-vpn-design.md`).

## Global Constraints

- Precedence is env > db > default; env-sourced fields are read-only in the UI and never written to `config_settings`.
- Overlay keys are `built_in_torrent.<field>`; `ConfigSetting` category `:built_in_torrent`.
- `vpn_provider` and `vpn_type` are trimmed, downcased strings. Never `String.to_atom/1`, never `Loader.parse_atom/1`.
- Secrets (`vpn_openvpn_password`, `vpn_wireguard_private_key`) are `redact: true`, never rendered into HTML, never logged.
- Settings file: `/config/gluetun/settings.env`, mode 600, owner `mydia`, atomic temp+rename, `KEY=value` lines, no newline in any value.
- Loop status file: `/config/gluetun/loop-status`, lines `hash=<sha256 hex or none>` and `dropped=<comma-separated keys>`.
- Allowlisted file keys: `VPN_ENABLED VPN_SERVICE_PROVIDER VPN_TYPE OPENVPN_USER OPENVPN_PASSWORD WIREGUARD_PRIVATE_KEY WIREGUARD_ADDRESSES SERVER_COUNTRIES SERVER_REGIONS SERVER_CITIES SERVER_HOSTNAMES VPN_PORT_FORWARDING`. `VPN_ENABLED` controls the loop and is never passed to gluetun.
- Control-server routes allowed: `GET /v1/vpn/status`, `GET /v1/publicip/ip`, `GET /v1/portforward`.
- Apply timeout: 30 seconds. Loop poll: 2 seconds.
- Tests never set real environment variables; pass env maps or `getenv` functions (`test/README.md`).
- No em dashes in code comments, docs or UI copy. New UI strings go through `gettext`; follow `lib/mydia_web/gettext/README.md` for catalog updates.
- Commit with plain `git commit -F <file>` inside the worktree; verify each with `git show --stat`.

## Review Focus

1. A VPN settings change while gluetun still runs the previous settings: the engine must stay stopped until `loop-status` reports the new hash, even though gluetun answers `running` and the leak check would pass on the old tunnel (Task 5).
2. Saving the form with a secret field left blank must keep the stored secret, not clear it (Task 7).
3. Saving an unrelated setting (language, server) must not restart the torrent engine (Task 6).
4. A password containing `=`, quotes, `$` or spaces must reach gluetun byte for byte; one containing a newline must be refused at save (Tasks 3, 4, 7).
5. Crafted form params naming an env-locked field must write no row and change nothing (Task 7).

---

### Task 1: `built_in_torrent` config section and reload broadcast

**Files:**
- Create: `lib/mydia/config/schema/built_in_torrent.ex`
- Modify: `lib/mydia/config/schema.ex` (add `embeds_one :built_in_torrent, Mydia.Config.Schema.BuiltInTorrent, on_replace: :update` beside `:flaresolverr`, and its `cast_embed`)
- Modify: `lib/mydia/config/loader.ex` (`load_env/0` gains `built_in_torrent: load_built_in_torrent_env()`; `reload/1` broadcasts)
- Modify: `lib/mydia/settings/config_setting.ex` (`@categories` gains `:built_in_torrent`)
- Test: `test/mydia/config/schema/built_in_torrent_test.exs`, `test/mydia/config/loader_built_in_torrent_test.exs`

**Interfaces:**
- Produces: `%Mydia.Config.Schema.BuiltInTorrent{enabled: boolean | nil, download_path: String.t, state_path: String.t, listen_port: integer, api_port: integer, vpn_enabled: boolean, vpn_provider, vpn_type, vpn_openvpn_user, vpn_openvpn_password, vpn_wireguard_private_key, vpn_wireguard_addresses, vpn_server_countries, vpn_server_regions, vpn_server_cities, vpn_server_hostnames :: String.t | nil, vpn_port_forwarding: boolean}`, defaults per the spec table (`enabled: nil`, `"/data/downloads"`, `"/config/rqbit"`, `51413`, `3030`, `vpn_enabled: false`, `vpn_port_forwarding: false`).
- Produces: `BuiltInTorrent.env_vars() :: [{field :: atom, env_var :: String.t}]`, the single field-to-variable table (Loader, Settings and the UI all read it). `vpn_enabled` maps to `"MYDIA_VPN_SERVICE_PROVIDER"`.
- Produces: `BuiltInTorrent.secret_fields() :: [:vpn_openvpn_password, :vpn_wireguard_private_key]`.
- Produces: `Mydia.Config.Loader.topic() :: "config:runtime"`; message `{:runtime_config_reloaded, config}` broadcast on `Mydia.PubSub` after `Application.put_env` in `reload/1`.

- [ ] **Step 1: Write failing tests**

`built_in_torrent_test.exs`: `changeset/2` with `%{"vpn_provider" => " ProtonVPN ", "vpn_type" => "WireGuard"}` yields `"protonvpn"` and `"wireguard"`; listen_port `0` and `70000` are invalid (`1..65535`); `inspect/1` of a struct with `vpn_openvpn_password: "hunter2"` does not contain `"hunter2"`; `env_vars/0` has 17 rows, one per field, and maps `:vpn_enabled` to `"MYDIA_VPN_SERVICE_PROVIDER"`.

`loader_built_in_torrent_test.exs` (drive `load_built_in_torrent_env/1` through a public `@doc false` `built_in_torrent_env(getenv)` so tests pass a function): `MYDIA_TORRENT_PORT=6881` gives `listen_port: 6881`; `MYDIA_TORRENT_PORT=abc` leaves the key out; `MYDIA_TORRENT_ENABLED=off` gives `enabled: false`; `MYDIA_TORRENT_ENABLED=maybe` leaves it out; a non-blank `MYDIA_VPN_SERVICE_PROVIDER` gives `vpn_enabled: true` and `vpn_provider`; `MYDIA_VPN_VPN_PORT_FORWARDING=on` gives `vpn_port_forwarding: true`. A third test subscribes to `Loader.topic()`, calls `Loader.reload(sources: [:yaml, :env])`, and `assert_receive {:runtime_config_reloaded, %Mydia.Config.Schema{}}`.

- [ ] **Step 2: Run** `./dev mix test test/mydia/config/schema/built_in_torrent_test.exs test/mydia/config/loader_built_in_torrent_test.exs`; expect failures (module missing).

- [ ] **Step 3: Implement.** Schema module follows `lib/mydia/config/schema/flaresolverr.ex`. `load_built_in_torrent_env/1` builds from `env_vars/0` with parsers: integers via `parse_integer/1`, booleans via the existing truthy/falsy parser, strings trimmed (provider and type also downcased), `vpn_enabled` true when the provider is non-blank. Put it in `load_env/0`. Broadcast in `reload/1`'s `{:ok, config}` branch.

- [ ] **Step 4: Run** the two files plus `./dev mix test test/mydia/config test/mydia/settings`; expect PASS (the `Paths` overlay index picks up the new section automatically; `no_varchar_columns_test` is unaffected, no migration).

- [ ] **Step 5: Commit** `feat(config): add the built_in_torrent section and a reload broadcast`.

---

### Task 2: Build `BuiltIn.Config` from the runtime config

**Files:**
- Modify: `lib/mydia/downloads/built_in/config.ex`
- Test: `test/mydia/downloads/built_in/config_test.exs` (rewrite callers of `load/3`)

**Interfaces:**
- Consumes: `BuiltInTorrent` struct and `env_vars/0` (Task 1).
- Produces: `Config.from_runtime(section :: BuiltInTorrent.t(), env :: map, other_client_types :: [atom] | :unknown, opts :: keyword) :: Config.t()`, replacing `load/3` (same `opts`: `:find_executable`, `:file_exists?`, `:name_taken`). New struct fields: `vpn_type :: String.t | nil`, `vpn_section :: BuiltInTorrent.t()` (the section the VPN file is rendered from), `env_vpn_names :: [String.t]` (sorted `MYDIA_VPN_*` names set in env that are not in `env_vars/0`), `source :: :env | :database | :default` for `enabled`. `vpn?` now means `section.vpn_enabled`. `explicit` is `section.enabled`.
- Produces: `Config.restart_key(Config.t()) :: map`, the config without `warnings`, used by Task 6 to decide restarts.

- [ ] **Step 1: Write failing tests.** Port every existing `load/3` test to `from_runtime/4` with a section struct instead of env vars. Add: `vpn_type: "wireguard"` gives `vpn_interface: "wg0"`, `"openvpn"` or nil gives `"tun0"`, env `MYDIA_VPN_VPN_INTERFACE=tun5` overrides both; env `%{"MYDIA_VPN_SERVER_NAMES" => "x", "MYDIA_VPN_OPENVPN_USER" => "u"}` gives `env_vpn_names: ["MYDIA_VPN_SERVER_NAMES"]`; the invalid-value warnings (`{:invalid_port, v}`, `{:invalid_enabled, v}`) are still produced from env strings; reserved-variable warnings now include `HTTP_CONTROL_SERVER_AUTH_CONFIG_FILEPATH`; `restart_key/1` of two configs differing only in `warnings` are equal.

- [ ] **Step 2: Run** `./dev mix test test/mydia/downloads/built_in/config_test.exs`; expect FAIL.

- [ ] **Step 3: Implement** `from_runtime/4`. Values come from the section; env is read only for warnings, reserved names, `MYDIA_VPN_VPN_INTERFACE` and `env_vpn_names`. Remove `load/3`. Add `HTTP_CONTROL_SERVER_AUTH_CONFIG_FILEPATH` to `@reserved`.

- [ ] **Step 4: Run** the file; expect PASS. `BuiltIn.Supervisor` no longer compiles against `load/3`; Task 6 replaces that call, so for now change its call site to `Config.from_runtime(Mydia.Settings.get_runtime_config().built_in_torrent, System.get_env(), types, name_taken: name_taken?)` and run `./dev mix test test/mydia/downloads/built_in`; expect PASS.

- [ ] **Step 5: Commit** `refactor(downloads): build the built-in client's config from the layered section`.

---

### Task 3: Provider table and the settings file writer

**Files:**
- Create: `lib/mydia/downloads/built_in/vpn_providers.ex`, `lib/mydia/downloads/built_in/vpn_settings.ex`
- Test: `test/mydia/downloads/built_in/vpn_providers_test.exs`, `test/mydia/downloads/built_in/vpn_settings_test.exs`

**Interfaces:**
- Consumes: `Config` (Task 2), `BuiltInTorrent.env_vars/0` (Task 1).
- Produces: `VpnProviders.gluetun_version() :: "v3.41.3"`; `VpnProviders.all() :: [%{name: String.t, label: String.t, types: [String.t], port_forwarding?: boolean}]`; `VpnProviders.get(name) :: map | nil`.
- Produces: `VpnSettings.render(Config.t(), env :: map) :: String.t` (deterministic, keys in allowlist order, `VPN_ENABLED=true|false` first, fields whose env var is set omitted, nil fields omitted, booleans as `on`/`off`); `VpnSettings.hash(String.t) :: String.t` (lowercase SHA-256 hex); `VpnSettings.write(Config.t(), env :: map) :: {:ok, hash} | {:error, {:vpn_settings_write_failed, posix}}` (skips the write when the file already holds identical bytes, still returns the hash); `VpnSettings.path(Config.t()) :: Path.t` (`Path.join(config.gluetun_dir, "settings.env")`).

- [ ] **Step 1: Write failing tests.** Providers: `gluetun_version()` equals `String.trim(File.read!("vendor/gluetun/VERSION"))`; every entry has a non-empty `types` subset of `["openvpn", "wireguard"]`; `get("protonvpn")` supports both types with port forwarding; `get("private internet access")` is OpenVPN-only with port forwarding; `get("mullvad")` has no port forwarding. Settings: render with provider `"mullvad"`, type `"wireguard"`, key `"a=b$c 'd\""` produces exactly `"VPN_ENABLED=true\nVPN_SERVICE_PROVIDER=mullvad\nVPN_TYPE=wireguard\nWIREGUARD_PRIVATE_KEY=a=b$c 'd\"\n"`; with env `%{"MYDIA_VPN_WIREGUARD_PRIVATE_KEY" => "x"}` the key line is absent; `write/2` into a tmp dir leaves mode `0o600` and no temp file behind; a second identical `write/2` does not change the file's mtime; writing into a read-only dir returns `{:error, {:vpn_settings_write_failed, :eacces}}`.

- [ ] **Step 2: Run** both files; expect FAIL.

- [ ] **Step 3: Implement.** Build the provider table from gluetun v3.41.3 sources: names from `internal/constants/providers/providers.go`, WireGuard support from the provider list in `internal/configuration/settings/wireguard.go`, port forwarding from `internal/configuration/settings/portforward.go`. Leave out `custom` (it needs a config file, which the UI does not take). Record the source paths in the moduledoc. Writer: temp file in the same dir, `File.chmod(tmp, 0o600)`, `File.rename/2`.

- [ ] **Step 4: Run** both files; expect PASS.

- [ ] **Step 5: Commit** `feat(downloads): gluetun provider table and the VPN settings file`.

---

### Task 4: Root loop applies the settings file; control server locked down

**Files:**
- Modify: `docker/vpn-preflight.sh`
- Test: `test/mydia/downloads/built_in/vpn_preflight_script_test.exs`

**Interfaces:**
- Consumes: the file format from Task 3.
- Produces (shell functions, testable with `VPN_PREFLIGHT_FUNCTIONS_ONLY=1`): `read_settings_file <path>` sets the positional args to the allowlisted `KEY=value` pairs (minus `VPN_ENABLED`) and sets `dropped` and `settings_enabled`; `run_with_gluetun_env <bin> <gid> <apikey> <settings-file>` now takes the file and passes file pairs, then `MYDIA_VPN_*` env, then Mydia's own; `write_auth_toml <path> <apikey>`; `write_loop_status <path> <hash> <dropped>`.
- Produces: `loop-status` and `auth.toml` in `/config/gluetun`.

- [ ] **Step 1: Write failing tests** (same style as the existing file):
  - a file with `VPN_SERVICE_PROVIDER=mullvad`, `OPENVPN_PASSWORD=p=q $x 'y"` and `FIREWALL=off` passes `VPN_SERVICE_PROVIDER=mullvad` and the password byte for byte, does not pass `FIREWALL=off`, and `dropped` is `FIREWALL`;
  - `VPN_ENABLED=true` in the file is never passed to gluetun;
  - env `MYDIA_VPN_SERVER_COUNTRIES=Canada` beats file `SERVER_COUNTRIES=Germany` (last occurrence wins under `env -i`);
  - the output contains `HTTP_CONTROL_SERVER_AUTH_CONFIG_FILEPATH=/config/gluetun/auth.toml` and `HTTP_CONTROL_SERVER_AUTH_DEFAULT_ROLE={}`, and a user `MYDIA_VPN_HTTP_CONTROL_SERVER_AUTH_CONFIG_FILEPATH` does not win;
  - `write_auth_toml` output parses as one `[[roles]]` entry with `auth = "apikey"`, the key, and `routes = ["GET /v1/vpn/status", "GET /v1/publicip/ip", "GET /v1/portforward"]`;
  - `write_loop_status` writes `hash=<h>\ndropped=<d>\n`.

- [ ] **Step 2: Run** `./dev mix test test/mydia/downloads/built_in/vpn_preflight_script_test.exs`; expect FAIL.

- [ ] **Step 3: Implement.** Read the file with `while IFS= read -r line`, `key=${line%%=*}`, `value=${line#*=}`, a `case` over the allowlist; no `eval` of values. Main body: write the preflight file whenever `MYDIA_TORRENT_ENABLED` is not falsy in env; with caps and group present, generate the key, write `auth.toml` (root-owned, 600), and start a loop that every 2s computes `sha256sum` of `settings.env` (`none` when absent), runs gluetun when the file says `VPN_ENABLED=true` or `MYDIA_VPN_SERVICE_PROVIDER` is non-blank, restarts it when the hash changes, stops it when neither enables the VPN, and writes `loop-status` after each start or stop. Gluetun runs in the background inside the loop, so the loop can kill it. Keep log rotation per start.

- [ ] **Step 4: Run** the test file; expect PASS. Then `shellcheck docker/vpn-preflight.sh` (via `nix shell nixpkgs#shellcheck -c`); expect no findings.

- [ ] **Step 5: Commit** `feat(docker): apply UI VPN settings from a watched file, lock the control server`.

---

### Task 5: `Vpn` waits for the applied hash

**Files:**
- Create: `lib/mydia/downloads/built_in/preflight.ex`
- Modify: `lib/mydia/downloads/built_in/vpn.ex`, `lib/mydia/downloads/built_in/status.ex`
- Test: `test/mydia/downloads/built_in/vpn_test.exs`, `test/mydia/downloads/built_in/preflight_test.exs`

**Interfaces:**
- Produces: `Preflight.read(dir) :: {:ok, %{net_admin: :ok | :missing, tun: ..., split_group: ..., src_valid_mark: ...}} | :absent`; `Preflight.blocking_reason(map) :: nil | :missing_net_admin | :missing_tun | :split_group_missing`. `Vpn.preflight/1` uses it.
- Consumes: `Vpn` opts gain `:expected_hash` (from Task 6), `:apply_timeout_ms` (default `30_000`), `:loop_status_fun` (default reads `<gluetun_dir>/loop-status`, returns `{:ok, %{hash: String.t, dropped: [String.t]}} | :error`).
- Produces: `Status.describe/1` clauses for `{:vpn_settings_write_failed, posix}`, `{:vpn_settings_rejected, keys}`, `:vpn_apply_timeout`, `:vpn_applying` (copy from the spec's Errors table).

- [ ] **Step 1: Write failing tests** in `vpn_test.exs` with the existing fakes: loop status hash `"old"` while expected is `"new"` and gluetun reports running with a passing leak check: the engine never receives `{:start, _, _}` and Status vpn is `:connecting`; after `apply_timeout_ms: 0` the next poll sets `{:down, :vpn_apply_timeout}`; hash matches with `dropped: ["X"]` gives `{:down, {:vpn_settings_rejected, ["X"]}}`; hash matches, nothing dropped: the existing up path runs. `preflight_test.exs`: parses the four keys; `src_valid_mark=missing` alone is not blocking.

- [ ] **Step 2: Run** both files; expect FAIL.

- [ ] **Step 3: Implement.** In `poll/1`, after `preflight` and before `client`, add a `loop_status` step: mismatch within the timeout is `connecting/1`; over it is `{:down, :vpn_apply_timeout}`; dropped keys are `{:down, {:vpn_settings_rejected, keys}}`. Measure the timeout from `init`.

- [ ] **Step 4: Run** `./dev mix test test/mydia/downloads/built_in`; expect PASS.

- [ ] **Step 5: Commit** `feat(downloads): gate the engine on gluetun applying the current VPN settings`.

---

### Task 6: `Manager` applies config changes live

**Files:**
- Create: `lib/mydia/downloads/built_in/manager.ex`
- Modify: `lib/mydia/downloads/built_in/supervisor.ex` (takes `:config`, `:credentials`, `:api_port`, `:expected_hash` in opts; loses `build_children/1`, `remember/1` and `configured_clients/0`, which move to `Manager`), `lib/mydia/application.ex` (`built_in_torrent_children/0` returns `[{DynamicSupervisor, name: Mydia.Downloads.BuiltIn.Instances, strategy: :one_for_one}, Mydia.Downloads.BuiltIn.Manager]`)
- Test: `test/mydia/downloads/built_in/manager_test.exs`, `test/mydia/downloads/built_in/supervisor_test.exs`

**Interfaces:**
- Consumes: `Config.from_runtime/4`, `Config.restart_key/1` (Task 2); `VpnSettings.write/2` (Task 3); `Loader.topic/0` (Task 1).
- Produces: `Manager.start_link(opts)`; opts for tests: `:name`, `:instances` (DynamicSupervisor name), `:runtime_fun` (default `fn -> Settings.get_runtime_config().built_in_torrent end`), `:env_fun` (default `&System.get_env/0`), `:clients_fun`, `:rqbit_path`, `:gluetun_dir`. `Manager.current(server \\ Manager) :: Config.t() | nil` (last applied). `Manager.apply_now(server \\ Manager) :: :ok` (synchronous re-evaluation for tests).

- [ ] **Step 1: Write failing tests** with a fake `rqbit` script (as `engine_test.exs` does) and a tmp gluetun dir:
  - a `{:runtime_config_reloaded, _}` with an unchanged section leaves the instance pid unchanged;
  - changing `listen_port` replaces the instance pid and `BuiltIn.runtime()`;
  - changing `enabled` to `false` terminates the instance and clears the runtime;
  - with `vpn_enabled: true`, `settings.env` exists with `VPN_ENABLED=true` and the started `Vpn` got `expected_hash` equal to `VpnSettings.hash/1` of the file;
  - with the client disabled, `settings.env` holds `VPN_ENABLED=false`;
  - a `runtime_fun` that raises leaves `Manager` alive with no instance and logs the error.

- [ ] **Step 2: Run** both files; expect FAIL.

- [ ] **Step 3: Implement.** `init` subscribes to `Loader.topic()` and applies in `handle_continue`. Apply: build config; `remember` the marker; write the VPN file (a write error becomes a Status warning on the new tree, not a crash); compare `restart_key`; on change `DynamicSupervisor.terminate_child` the old instance, then `put_runtime`/`clear_runtime` and `start_child` a `{BuiltIn.Supervisor, ...}` with fresh credentials. Terminating the old tree runs `Engine.terminate/2`, which already stops rqbit with its 15s shutdown.

- [ ] **Step 4: Run** `./dev mix test test/mydia/downloads/built_in test/mydia/downloads/client/rqbit_test.exs`; expect PASS.

- [ ] **Step 5: Commit** `feat(downloads): apply built-in client config changes without a restart`.

---

### Task 7: `BuiltIn.Settings`, the form's context API

**Files:**
- Create: `lib/mydia/downloads/built_in/settings.ex`
- Test: `test/mydia/downloads/built_in/settings_test.exs`

**Interfaces:**
- Consumes: `BuiltInTorrent` and `env_vars/0` (Task 1); `VpnProviders` (Task 3); `Mydia.Settings.upsert_config_setting/1`, `config_source/3`, `applied_config_settings_by_key/0`, `delete_config_setting/1`; `Loader.reload/0`.
- Produces: `Settings.form_changeset(params :: map, current :: BuiltInTorrent.t()) :: Ecto.Changeset.t()` (action `:validate`); `Settings.save(params :: map, opts :: keyword) :: :ok | {:error, Ecto.Changeset.t()}` (opts: `:getenv`, `:reload`, `:updated_by_id`); `Settings.sources(getenv \\ &System.get_env/1) :: %{atom => :env | :database | :default}`; `Settings.secret_saved?(field) :: boolean`; `Settings.active_download_count() :: non_neg_integer` (downloads with `download_client == BuiltIn.name()` and `completed_at: nil`); `Settings.off_reason(Config.t() | nil) :: :env | :ui | :automatic | :name_taken`.

- [ ] **Step 1: Write failing tests** (DataCase; `getenv` and `reload` injected):
  - provider `"mullvad"` with `vpn_type: "openvpn"` is valid; `vpn_type: "wireguard"` on `"private internet access"` is an error on `:vpn_type`; unknown provider is an error on `:vpn_provider`; `vpn_port_forwarding: true` on `"mullvad"` is an error;
  - a password containing `"\n"` is an error on `:vpn_openvpn_password`;
  - `save` with `vpn_openvpn_password: ""` when a row exists keeps the row's value;
  - `save` with params for a field whose env var is set (getenv returns a value) writes no row for it and returns `:ok`;
  - `save` with `enabled: "automatic"` deletes the `built_in_torrent.enabled` row; a blank `vpn_server_cities` deletes its row;
  - a `reload` returning `{:error, :boom}` rolls back every row written in that save;
  - `sources/1` reports `:env`, `:database` and `:default` correctly for three fields.

- [ ] **Step 2: Run** the file; expect FAIL.

- [ ] **Step 3: Implement** following `Mydia.Indexers.Cardigann.EngineSetting.save/2`: one `Repo.transaction` doing the upserts/deletes then `reload`, rolling back on any error. Only fields present in params, not env-locked, and changed are written. Values are encoded as the strings `Paths.cast_overlay/2` casts back (`"true"`, `"6881"`).

- [ ] **Step 4: Run** the file; expect PASS.

- [ ] **Step 5: Commit** `feat(downloads): context API for saving built-in client settings`.

---

### Task 8: Admin UI

**Files:**
- Modify: `lib/mydia_web/live/admin_download_clients_live/built_in_components.ex` (panel always rendered, Configure/Enable buttons, off state, setup card)
- Create: `lib/mydia_web/live/admin_download_clients_live/built_in_form_components.ex` (the modal and its two sections)
- Modify: `lib/mydia_web/live/admin_download_clients_live/index.ex` (assigns and events only; logic stays in `BuiltIn.Settings`)
- Test: `test/mydia_web/live/admin_download_clients_live/built_in_settings_test.exs`

**Interfaces:**
- Consumes: everything in Task 7; `Manager.current/0`; `Preflight.read/1`; `Config.env_vpn_names`.
- Produces DOM ids: `#built-in-configure`, `#built-in-enable`, `#built-in-off-reason`, `#built-in-settings-modal`, `#built-in-settings-form`, `#built-in-section-torrent`, `#built-in-section-vpn`, `#built-in-vpn-setup-card`, `#built-in-env-vpn-names`, `#built-in-confirm-disable`, `#built-in-confirm-vpn-off`, `#built-in-secret-replace-<field>`. Events: `open_built_in_settings`, `close_built_in_settings`, `built_in_section`, `validate_built_in`, `save_built_in`, `replace_built_in_secret`, `enable_built_in`.

- [ ] **Step 1: Write failing tests.** Env-dependent rendering is tested at the component level with `render_component/2`, passing `sources` and `env_vpn_names` assigns, so no test sets a real variable:
  - (component) a field with source `:env` renders `disabled` with an ENV badge;
  - (component) `#built-in-env-vpn-names` lists `MYDIA_VPN_SERVER_NAMES` and no value.

  The rest are LiveView tests:
  - with the client off, `#built-in-off-reason` renders and `#built-in-enable` is present;
  - opening the modal and switching provider to `"private internet access"` hides the VPN type control and shows the OpenVPN fields;
  - a saved password never appears in `render(view)`; `#built-in-secret-replace-vpn_openvpn_password` is present;
  - unchecking enabled with an active built-in download shows `#built-in-confirm-disable` naming the count before saving;
  - turning the VPN off while the engine runs shows `#built-in-confirm-vpn-off`;
  - a preflight file with `net_admin=missing` shows `#built-in-vpn-setup-card` containing `NET_ADMIN`, `/dev/net/tun` and `net.ipv4.conf.all.src_valid_mark=1`, and the VPN toggle is disabled.

- [ ] **Step 2: Run** the file; expect FAIL.

- [ ] **Step 3: Implement.** Page-level `<dialog class="modal">`, `<.segmented_control>` for the two sections and the VPN type, `<.input>` for fields, the existing source-badge component used by `admin_settings_live`. The panel subscribes to `Status.topic()` whether or not the client runs, so enabling it shows progress live. Keep each component file under about 500 lines.

- [ ] **Step 4: Run** the file and `./dev mix test test/mydia_web/live/admin_download_clients_live_test.exs`; expect PASS.

- [ ] **Step 5: Browser check.** Start the stack (`./dev up -d`), log in, open Admin, Download Clients, the modal at 375px width; confirm no horizontal scroll and that toasts paint above the modal. Record the measurement in the commit message body.

- [ ] **Step 6: Commit** `feat(admin): configure the built-in torrent client and VPN from the UI`.

---

### Task 9: Docs and final verification

**Files:**
- Modify: `docs/using/reference/download-clients.md` (lead with the UI flow), `docs/using/reference/environment-variables.md` (variables as overrides), `vendor/gluetun/README.md` (UI-driven smoke test, auth.toml lockdown), `lib/mydia/downloads/README.md` (Manager, settings file, loop-status)

- [ ] **Step 1:** Update the four docs; no em dashes.
- [ ] **Step 2:** `./dev mix precommit` in chunks per `test/README.md` if it exceeds the Bash timeout; expect zero failures and no warnings.
- [ ] **Step 3:** `git diff --stat origin/master...HEAD`; every file listed appears in some task above.
- [ ] **Step 4: Commit** `docs: UI-driven built-in torrent client and VPN`.

Manual (after merge, by the maintainer): the Docker smoke test from `vendor/gluetun/README.md`, including that `PUT /v1/vpn/settings` with the BEAM's key is refused.
