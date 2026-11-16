# Outbound HTTP Proxy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route all outbound internet HTTP made through Req via one configurable HTTP(S) proxy, with LAN targets direct and the plugin SSRF gate's guarantees intact (issue #1437).

**Architecture:** A `proxy` config section (yaml -> db -> env, falling back to `HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY`) is parsed by `Mydia.Net.Proxy` into a cached struct. A global Req adapter, `Mydia.Net.ProxyAdapter`, installed once via `Req.default_options/1`, decides per request whether to add Mint's `connect_options[:proxy]`, then delegates to `Req.Finch.run/1`. Error paths call `Mydia.Net.Proxy.describe_error/2` for messages that name the proxy.

**Tech Stack:** Elixir, Req 0.7.5, Finch 0.24, Mint 1.11 (`Mint.TunnelProxy`), Phoenix LiveView, ExUnit + Bypass.

**Spec:** `design/specs/2026-11-16-outbound-http-proxy-design.md`

## Global Constraints

- HTTP and HTTPS proxies only. `socks4://`, `socks5://` and any other scheme fail config validation by name.
- Env vars: `MYDIA_PROXY_URL`, `MYDIA_PROXY_BYPASS` (comma-separated). Fallback, only when the layered value is unset: URL from the first non-empty of `HTTPS_PROXY`, `https_proxy`, `HTTP_PROXY`, `http_proxy`; bypass from `NO_PROXY`, then `no_proxy`.
- Routing never does DNS lookups.
- `Mydia.Plugins.Net.Gate`'s validate/resolve/pin logic does not change.
- Proxy credentials never appear in logs, flash messages, rendered HTML or error strings. Display form is `http://user:****@host:port`.
- Tests never mutate process env (`test/README.md`); env reads go through an injectable `getenv` function.
- Migrations: none needed (`config_settings.category` is a text-backed `Ecto.Enum`; adding a value is code-only).
- No em dashes in user-facing copy or docs. Wrap UI strings in `gettext`.
- `bypass` is stored as one comma-separated string in the schema (DB overlay rows are single strings), parsed by `Mydia.Net.Proxy`.

## Review Focus

1. **A Docker service name with a dot** (`qbittorrent.lan`, `nas.local`) is not auto-bypassed; it goes through the proxy unless listed in `bypass`. Expected: docs say so explicitly, and a unit test pins that `nas.local` routes to the proxy while `nas` does not (Task 2).
2. **Proxy URL with no port** (`http://prizrak`). Expected: default port 80 for `http`, 443 for `https`, not a validation error (Task 2 test).
3. **Credentials containing URL-escaped characters** (`p%40ss`). Expected: decoded before Base64 in `proxy-authorization`, and masked in display (Task 2 test).
4. **IPv6 literal targets and bypass entries** (`[fd00::1]`, `fd00::/8`). Expected: bracketed hosts are unwrapped before matching, private v6 goes direct (Task 2 test).
5. **Proxy saved in the UI while `HTTP_PROXY` is set in the container.** Expected: the DB value wins (layered beats standard fallback), and the row shows source `db` (Task 6 test).

---

### Task 1: `proxy` config section

**Files:**
- Create: `lib/mydia/config/schema/proxy.ex`
- Create: `lib/mydia/config/env/proxy_env.ex`
- Modify: `lib/mydia/config/schema.ex` (type at ~line 62, `embeds_one` next to `:flaresolverr` at ~line 320, `cast_embed` at ~line 492, `defaults/0` at ~line 1053)
- Modify: `lib/mydia/config/loader.ex` (`load_env/0`, ~line 253: add `proxy: Mydia.Config.Env.ProxyEnv.load()`)
- Modify: `lib/mydia/settings/config_setting.ex` (`@categories`: add `:proxy`)
- Test: `test/mydia/config/schema/proxy_test.exs`, `test/mydia/config/env/proxy_env_test.exs`

**Interfaces:**
- Produces: `%Mydia.Config.Schema.Proxy{url: String.t() | nil, bypass: String.t() | nil}`; `config.proxy` on the runtime config (never nil after defaults); `Mydia.Config.Env.ProxyEnv.load(getenv \\ &System.get_env/1) :: map()` reading only `MYDIA_PROXY_URL`/`MYDIA_PROXY_BYPASS`; DB keys `"proxy.url"`, `"proxy.bypass"` with category `:proxy`.

- [ ] **Step 1: Write failing tests**

```elixir
# proxy_test.exs
test "accepts http and https proxy URLs, with and without port and credentials" do
  for url <- ["http://prizrak:7890", "https://p.example.com", "http://u:p%40ss@10.0.0.2:3128"] do
    assert %{valid?: true} = Proxy.changeset(%Proxy{}, %{url: url})
  end
end

test "rejects unsupported schemes and hostless URLs by name" do
  for url <- ["socks5://p:1080", "prizrak:7890", "http://", "ftp://p:21"] do
    cs = Proxy.changeset(%Proxy{}, %{url: url})
    refute cs.valid?
    assert {"must be an http:// or https:// proxy URL with a host", _} = cs.errors[:url]
  end
end

test "nil and empty url are valid (no proxy)" do
  assert %{valid?: true} = Proxy.changeset(%Proxy{}, %{url: nil})
end

# proxy_env_test.exs
test "reads only the Mydia-specific variables" do
  env = %{"MYDIA_PROXY_URL" => "http://p:1", "MYDIA_PROXY_BYPASS" => "a.com,b", "HTTP_PROXY" => "http://x:2"}
  assert ProxyEnv.load(&Map.get(env, &1)) == %{url: "http://p:1", bypass: "a.com,b"}
end
```

Add one loader test: a `config_settings` row `%{key: "proxy.url", value: "http://p:1", category: :proxy}` makes `Loader.load(sources: [:database])` return `config.proxy.url == "http://p:1"` (follow the existing DB-overlay tests in `test/mydia/config/loader_test.exs`).

- [ ] **Step 2: Run** `./dev mix test test/mydia/config/schema/proxy_test.exs test/mydia/config/env/proxy_env_test.exs`; expect FAIL (modules undefined).
- [ ] **Step 3: Implement.** Schema follows `Mydia.Config.Schema.FlareSolverr`. URL validation: `URI.parse/1`, scheme in `["http", "https"]`, non-empty host. `ProxyEnv.load/1` uses `Loader.put_if_present/3`.
- [ ] **Step 4: Run** the two test files plus `test/mydia/config/`; expect PASS.
- [ ] **Step 5: Commit** `feat(config): add proxy config section (#1437)`.

---

### Task 2: `Mydia.Net.Proxy` (parsing, effective config, routing, errors)

**Files:**
- Create: `lib/mydia/net/proxy.ex`
- Create: `lib/mydia/net/proxy/bypass.ex` (bypass entry parsing and matching)
- Test: `test/mydia/net/proxy_test.exs`, `test/mydia/net/proxy/bypass_test.exs`

**Interfaces:**
- Consumes: `%Mydia.Config.Schema.Proxy{}` (Task 1).
- Produces:
  - `%Mydia.Net.Proxy{proxy: {:http | :https, String.t(), :inet.port_number(), []}, headers: [{String.t(), String.t()}], bypass: [Bypass.entry()], display_url: String.t(), endpoint: String.t(), url_from: :config | :standard_env, bypass_from: :config | :standard_env | :none}`. `endpoint` is `"host:port"`.
  - `effective(proxy_config :: Proxy.t() | nil, getenv :: (String.t() -> String.t() | nil)) :: {:ok, t() | nil} | {:error, String.t()}` (nil = no proxy).
  - `route(host :: String.t() | nil, t() | nil) :: :direct | {:proxy, keyword()}` where the keyword is `[proxy: tuple, proxy_headers: headers]` (omit `proxy_headers` when empty).
  - `put_config(t() | nil) :: :ok`, `current() :: t() | nil` (`:persistent_term` key `{Mydia.Net.Proxy, :config}`).
  - `describe_error(exception, host :: String.t() | nil) :: String.t() | nil`.
  - `Bypass.parse(String.t() | nil) :: [entry]`, `Bypass.match?(host :: String.t(), [entry]) :: boolean`. Entries: `:any | {:domain, String.t()} | {:ip, :inet.ip_address()} | {:cidr, :inet.ip_address(), non_neg_integer()}`.

- [ ] **Step 1: Write failing tests.** Table-driven; build configs with `effective/2` and a map-backed `getenv`.

`effective/2`:
- layered `url` beats `HTTPS_PROXY`; `HTTPS_PROXY` beats `https_proxy` beats `HTTP_PROXY` beats `http_proxy`; `url_from` is `:config` or `:standard_env` accordingly.
- layered `bypass` beats `NO_PROXY` beats `no_proxy`; `bypass_from` set accordingly, `:none` when neither.
- nothing set -> `{:ok, nil}`.
- `"http://prizrak"` -> port 80; `"https://p"` -> 443 (Review Focus 2).
- `"http://u:p%40ss@h:1"` -> `headers == [{"proxy-authorization", "Basic " <> Base.encode64("u:p@ss")}]`, `display_url == "http://u:****@h:1"` (Review Focus 3).
- `HTTP_PROXY=socks5://x:1` -> `{:error, "unsupported proxy URL in HTTP_PROXY: socks5 is not supported"}` (the message names the variable and never includes credentials).

`route/2` (with proxy `http://prizrak:7890`, bypass `"example.org,.corp.test,203.0.113.7,198.51.100.0/24,fd00::/8"`):

| host | expected |
| --- | --- |
| `"tracker.example.com"` | `{:proxy, _}` |
| `"localhost"`, `"jellyfin"`, `"JELLYFIN."` | `:direct` |
| `"nas.local"` | `{:proxy, _}` (Review Focus 1) |
| `"192.168.1.5"`, `"10.0.0.1"`, `"100.64.0.1"`, `"127.0.0.1"`, `"::1"`, `"[fd12::1]"` | `:direct` (Review Focus 4) |
| `"example.org"`, `"www.EXAMPLE.org"`, `"a.corp.test"`, `"corp.test"` | `:direct` |
| `"notexample.org"` | `{:proxy, _}` |
| `"203.0.113.7"`, `"198.51.100.42"` | `:direct` |
| `"198.51.101.1"`, `"93.184.216.34"` | `{:proxy, _}` |
| `nil` | `:direct` |
| any host with config `nil` | `:direct` |
| any host with bypass `"*"` | `:direct` |

`describe_error/2` (proxy `prizrak:7890`, host routed to proxy):
- `%Req.HTTPError{reason: {:proxy, {:unexpected_status, 407}}}` -> `"proxy prizrak:7890 requires authentication"`
- `%Req.HTTPError{reason: {:proxy, {:unexpected_status, 502}}}` -> `"proxy prizrak:7890 refused the tunnel (HTTP 502)"`
- same two with `%Mint.HTTPError{}` -> same strings
- `%Req.TransportError{reason: :econnrefused}` -> `"connection through proxy prizrak:7890 failed: econnrefused"`
- any of the above for a `:direct` host -> `nil`

- [ ] **Step 2: Run** `./dev mix test test/mydia/net/`; expect FAIL.
- [ ] **Step 3: Implement.** Private-IP check reuses `Mydia.Plugins.Net.Gate.public_ip?/1` on `:inet.parse_address/1` of the de-bracketed host. Domain match: lowercase, strip trailing dot and leading dot of the entry, then `host == d or String.ends_with?(host, "." <> d)`. CIDR match on IP-literal hosts only, same address family, compare the top `bits` bits. Single-label = no `.` after stripping a trailing dot and the host is not an IP literal.
- [ ] **Step 4: Run**; expect PASS.
- [ ] **Step 5: Commit** `feat(net): proxy routing and error descriptions (#1437)`.

---

### Task 3: Global adapter, config caching, gate behaviour under proxy

**Files:**
- Create: `lib/mydia/net/proxy_adapter.ex`
- Create: `test/support/connect_proxy.ex` (in-test proxy)
- Modify: `lib/mydia/application.ex:57` (after `put_env :runtime_config`: `Mydia.Net.Proxy.refresh(config)`; then `Req.default_options(Keyword.put(Req.default_options(), :adapter, &Mydia.Net.ProxyAdapter.run/1))`)
- Modify: `lib/mydia/config/loader.ex:100` (`reload/1`: call `Mydia.Net.Proxy.refresh(config)` before broadcasting)
- Modify: `lib/mydia/net/proxy.ex` (add `refresh/1`)
- Modify: `lib/mydia/indexers/cardigann/bench/net_timer.ex:53` (`Req.Finch.run(request)` -> `Mydia.Net.ProxyAdapter.run(request)`)
- Modify: `lib/mydia/plugins/net/gate.ex` (moduledoc paragraph only)
- Test: `test/mydia/net/proxy_adapter_test.exs`, `test/mydia/plugins/net/gate_proxy_test.exs`

**Interfaces:**
- Consumes: `Proxy.route/2`, `Proxy.current/0`, `Proxy.put_config/1`, `Proxy.effective/2` (Task 2).
- Produces:
  - `Mydia.Net.ProxyAdapter.run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t() | Exception.t()}`.
  - `Mydia.Net.Proxy.refresh(Mydia.Config.Schema.t()) :: :ok`: computes `effective(config.proxy, &System.get_env/1)` and `put_config/1`s it; on `{:error, msg}` logs a warning with `msg`, stores `nil`.
  - `Mydia.Test.ConnectProxy.start(opts) :: {:ok, %{port: integer, log: pid}}` with opts `respond: :forward | {:status, integer}`; `Mydia.Test.ConnectProxy.requests(log) :: [String.t()]` (request lines, e.g. `"CONNECT 93.184.216.34:443 HTTP/1.1"`). Plain `:gen_tcp` listener under the test's supervisor: reads the request head and records its first line. With `{:status, s}` it answers that status and closes. With `:forward` it dials `127.0.0.1:<port>`, taking the port from the CONNECT authority or the absolute-form URL and **ignoring the host**, then for CONNECT answers `HTTP/1.1 200 Connection established` and pipes both ways, and for absolute-form replays the head and pipes.

**Adapter rules (from the spec):** effective host is `request.options[:connect_options][:hostname]` when set, else `request.url.host`. If `connect_options` already has `:proxy`, pass through untouched. Merge on `{:proxy, opts}`. Delegate to `Req.Finch.run/1`.

**Test topology:** loopback targets route direct, so proxied tests address the target as `http://tracker.example.test:<bypass_port>`. That name has a dot and is not an IP literal, so `route/2` proxies it; Mint sends it to the proxy without resolving it locally; the `:forward` helper maps it back to loopback. Document this in the helper's moduledoc.

- [ ] **Step 1: Write failing tests**

`proxy_adapter_test.exs` (async: false; each test `put_config` and restores `nil` in `on_exit`):
- `"sends a public host through the proxy"`: Bypass is plain HTTP, so Mint uses absolute-form; assert the proxy log's first line is `"GET http://tracker.example.test:#{bypass.port}/x HTTP/1.1"` and the Bypass body comes back.
- `"leaves a single-label host direct"`: `Req.get("http://localhost:#{bypass.port}/x")` succeeds and `requests(log) == []`.
- `"respects a caller-set connect_options proxy"`: two proxies; the configured one stays empty, the caller's one is used.
- `"a 407 surfaces as a proxy authentication error"`: proxy `respond: {:status, 407}`, HTTPS target `https://tracker.example.test/`; `{:error, err} = Req.get(...)` and `Proxy.describe_error(err, "tracker.example.test") == "proxy 127.0.0.1:#{port} requires authentication"`.
- `"a config refresh takes effect on the next request"`: request direct with `nil` config, `Proxy.refresh/1` with a proxy, next request appears in the proxy log.

`gate_proxy_test.exs`:
- `"gate request is tunnelled to the validated IP"`: `Gate.request("https://tracker.example.test/", allowed_hosts: ["tracker.example.test"], resolver: fn _ -> {:ok, [{93, 184, 216, 34}]} end)` with proxy `respond: {:status, 403}`; assert the proxy log's first line is `"CONNECT 93.184.216.34:443 HTTP/1.1"` (proves pinning survives proxying; the 403 keeps the test offline).
- `"gate still refuses a private target when a proxy is configured"`: resolver returns `{:ok, [{10, 0, 0, 5}]}`; assert `{:error, %{type: :blocked}}` and `requests(log) == []`.

- [ ] **Step 2: Run** `./dev mix test test/mydia/net/proxy_adapter_test.exs test/mydia/plugins/net/gate_proxy_test.exs`; expect FAIL.
- [ ] **Step 3: Implement** adapter, `refresh/1`, application and loader hooks, NetTimer chain, and the Gate moduledoc paragraph: proxied requests CONNECT to the validated IP with SNI from `:hostname`; the proxy never resolves the name; DNS must still work in the container.
- [ ] **Step 4: Run** the new tests, then `./dev mix test test/mydia/plugins test/mydia/indexers/cardigann`; expect PASS (no regression from the global adapter).
- [ ] **Step 5: Commit** `feat(net): global proxy-aware Req adapter (#1437)`.

---

### Task 4: Readable proxy errors in both Cardigann engines and the health check

**Files:**
- Modify: `lib/mydia/indexers/cardigann_search_engine.ex:479-480` and `:559-560`
- Modify: `lib/mydia/indexers/cardigann_health_check.ex:668-669`
- Modify: `lib/mydia/plugins/net/gate.ex:482-486` (`classify_transport_error/1` gains the host)
- Modify: `lib/mydia/indexers/cardigann/wasm/host_http.ex` (record proxy failures), `lib/mydia/indexers/cardigann/wasm/adapter.ex:410-416` (surface them)
- Test: extend `test/mydia/indexers/cardigann_search_engine_test.exs`, `test/mydia/indexers/cardigann_health_check_test.exs`, `test/mydia/indexers/cardigann/wasm/adapter_test.exs` (or the nearest existing WASM adapter test)

**Interfaces:**
- Consumes: `Proxy.describe_error/2` (Task 2), `Mydia.Test.ConnectProxy` (Task 3).
- Produces: `Error.connection_failed(msg)` where `msg` is the `describe_error/2` string whenever it is non-nil; otherwise today's message unchanged. Gate: `%Mydia.Plugins.Error{type: :network_error, message: msg}` with the same string. WASM ctx key `:proxy_note` holding an `Agent` pid whose state is the last `describe_error/2` string or `nil`.

- [ ] **Step 1: Write failing tests** (proxy helper `respond: {:status, 407}`, proxy configured via `Proxy.put_config/1`):
- native engine search against `https://tracker.example.test/` returns `{:error, %Error{message: "proxy 127.0.0.1:<port> requires authentication"}}`.
- native engine with no proxy configured and a closed port still returns a message starting `"Connection failed: "` (unchanged).
- health check `test_connection` returns `error: "proxy 127.0.0.1:<port> requires authentication"`.
- WASM adapter search where every request fails through the proxy returns `{:error, %Error{message: "proxy 127.0.0.1:<port> requires authentication"}}` instead of `"No answer from the tracker"`.
- [ ] **Step 2: Run** those tests; expect FAIL.
- [ ] **Step 3: Implement.** Native engine and health check: compute the message with `Proxy.describe_error(reason_exception, URI.parse(url).host) || <existing message>`. Gate: pass `uri.host` into `classify_transport_error/2`. WASM: the adapter starts an `Agent` per search (linked, stopped after), puts `proxy_note:` in ctx next to `put_login_watch/2`; `host_http.ex` `send_once/2` writes the gate error message into it when the message starts with `"proxy "` or `"connection through proxy "`; `failure_error(nil)` uses the note when set.
- [ ] **Step 4: Run** the touched test files in full; expect PASS.
- [ ] **Step 5: Commit** `feat(indexers): name the proxy in Cardigann connection errors (#1437)`.

---

### Task 5: Settings page proxy row, modal and Test proxy

**Files:**
- Create: `lib/mydia_web/live/admin_settings_live/proxy_settings.ex` (load values and sources, validate, persist, test) and `lib/mydia_web/live/admin_settings_live/proxy_components.ex` (`proxy_row/1`, `proxy_modal/1`), following `language_settings.ex` / `language_components.ex` and the FlareSolverr row in `admin_indexers_live/flaresolverr_components.ex`.
- Modify: `lib/mydia_web/live/admin_settings_live/index.ex` (assigns, `handle_event`s: `"edit_proxy"`, `"validate_proxy"`, `"save_proxy"`, `"close_proxy_modal"`, `"test_proxy"`), `components.ex` (render `proxy_row` in `general_settings_tab/1` after the language section).
- Modify: `lib/mydia/net/proxy.ex` (add `test_connection/1`)
- Test: `test/mydia_web/live/admin_settings_live/proxy_test.exs`, plus a unit test for `test_connection/1` in `test/mydia/net/proxy_test.exs`

**Interfaces:**
- Consumes: `Proxy.current/0`, `Proxy.effective/2`, `Settings.config_source/3`, `Settings.upsert_config_setting/1`, `Mydia.Config.Loader.reload/0`, `Mydia.Metadata.metadata_relay_url/0`.
- Produces:
  - `Mydia.Net.Proxy.test_connection(url :: String.t()) :: {:ok, %{status: integer, ms: non_neg_integer}} | {:error, String.t()}`: one `Req.get/2` to `url`, forcing `connect_options: route-ignoring proxy opts from current()`, `retry: false`, `receive_timeout: 10_000`; error strings via `describe_error/2` falling back to `Exception.message/1`. Returns `{:error, "No proxy is configured"}` when `current()` is nil.
  - DOM ids: `#proxy-row`, `#proxy-url-value`, `#proxy-source`, `#proxy-edit`, `#proxy-modal`, `#proxy-form`, `#proxy-test`, `#proxy-test-result`.
  - Source labels: `:env` (MYDIA_PROXY_*), `:db`, `:yaml`/`:default` as `config_source/3` returns, plus `:standard_env` when `url_from == :standard_env`, rendered "HTTP_PROXY env".

- [ ] **Step 1: Write failing tests**
- row renders `#proxy-url-value` with `http://u:****@p:1` and never the password (`refute render(view) =~ "secret"`) for a configured proxy.
- with `HTTP_PROXY` fallback only (inject via `Proxy.put_config(effective(nil, getenv))`), `#proxy-source` reads "HTTP_PROXY env".
- saving `proxy[url]=http://p:3128` writes a `"proxy.url"` row with category `:proxy`, reloads, and `#proxy-source` reads DB even when the injected standard fallback is present (Review Focus 5).
- saving `socks5://p:1` shows the Task 1 validation message in `#proxy-form` and writes nothing.
- `MYDIA_PROXY_URL`-sourced field renders disabled (the FlareSolverr env pattern).
- `#proxy-test` is disabled when no proxy is configured; with the ConnectProxy helper in front of a Bypass "relay" (`Application.put_env(:mydia, :metadata_relay_url, ...)` restored in `on_exit`), clicking it renders `#proxy-test-result` containing `200`; with `respond: {:status, 407}` it contains "requires authentication".
- [ ] **Step 2: Run** `./dev mix test test/mydia_web/live/admin_settings_live/proxy_test.exs`; expect FAIL.
- [ ] **Step 3: Implement.** Test target is `Mydia.Metadata.metadata_relay_url() <> "/health"`. Run the test with `start_async` so the LiveView stays responsive. Modal is a page-level `<dialog class="modal">` per `lib/mydia_web/components/README.md`. Run `./dev mix gettext.extract --merge` for new strings.
- [ ] **Step 4: Run** the LiveView test and `test/mydia_web/live/admin_settings_live/`; expect PASS.
- [ ] **Step 5: Commit** `feat(settings): proxy row with test button (#1437)`.

---

### Task 6: User docs and final verification

**Files:**
- Modify: `docs/using/reference/environment-variables.md` (new "Outbound proxy" section: `MYDIA_PROXY_URL`, `MYDIA_PROXY_BYPASS`, standard-variable fallback and precedence)
- Modify: `docs/using/reference/configuration.md` (`proxy:` YAML section with `url` and `bypass`; routing rules including "a name with a dot such as `nas.local` goes through the proxy unless listed"; HTTP/HTTPS only; the built-in torrent client, remote access and FlareSolverr's own fetches are not proxied; WASM indexers still need DNS in the container)

- [ ] **Step 1: Write the docs** (end-user voice, no implementation names beyond config keys).
- [ ] **Step 2: Run** `./dev mix precommit` in chunks per `reference_precommit_exceeds_bash_timeout` if it outruns the Bash timeout. Expected: no failures, no warnings.
- [ ] **Step 3: Run** `git diff --name-only origin/master...` and confirm only the files named in this plan (and `priv/gettext`) appear.
- [ ] **Step 4: Commit** `docs: outbound proxy configuration (#1437)`.
