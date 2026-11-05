# Built-in Torrent Client with Experimental VPN Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a built-in rqbit torrent engine that Mydia supervises, plus an opt-in, experimental split-tunnel VPN built on a patched gluetun, with every failure visible in the UI.

**Architecture:** `Mydia.Downloads.BuiltIn` supervises an `rqbit server` child and registers it as a runtime download client of type `rqbit`, driven by the existing `Rqbit` adapter. When the VPN is configured, the entrypoint starts a patched gluetun as root in split mode (only the `mydia-torrent` group and uid 0 are tunneled), and `BuiltIn.Vpn` gates the engine on gluetun's control API and a leak check. One `Status` process holds the combined state and feeds the adapter, `ClientHealth` and the admin row.

**Tech Stack:** Elixir/Phoenix LiveView, Req, Bypass, rqbit 9.x, gluetun v3.41.3 (Go) with a patch series, iptables/iproute2, Alpine Docker.

**Spec:** `design/specs/2026-11-04-builtin-torrent-vpn-design.md`

## Global Constraints

- Env vars: `MYDIA_TORRENT_ENABLED`, `MYDIA_TORRENT_DOWNLOAD_PATH` (default `/data/downloads`), `MYDIA_TORRENT_PORT` (default `51413`), `MYDIA_VPN_SERVICE_PROVIDER` (turns the VPN on), `MYDIA_VPN_*` (passed to gluetun, prefix stripped).
- Reserved gluetun variables Mydia sets itself: `SPLIT_TUNNEL_GID`, `HTTP_CONTROL_SERVER_ADDRESS`, `HTTP_CONTROL_SERVER_AUTH_DEFAULT_ROLE`, `DNS_ADDRESS`.
- Auto-enable: on when no client of type `qbittorrent`, `transmission`, `rqbit` or `rtorrent` is configured; `MYDIA_TORRENT_ENABLED=true|false` overrides.
- The BEAM never holds Linux capabilities. Gluetun runs as root, started by the entrypoint. rqbit and `torrent-curl` are setgid `mydia-torrent`.
- The engine never runs while the VPN is configured and not verified (`running` plus a passed leak check).
- Gluetun control server: `127.0.0.1:8000`, header `X-API-Key`, key in `/config/gluetun/apikey`; preflight in `/config/gluetun/preflight`; log in `/config/gluetun/gluetun.log`.
- rqbit CLI (9.x): global flags before `server start`; basic auth via env `RQBIT_HTTP_BASIC_AUTH_USERPASS=user:pass`.
- Tests never mutate global env (`test/README.md`, "Tests must not mutate global env"): every reader takes an env map or options argument.
- No real movie or TV titles in tests or fixtures.
- No em dashes in prose, docs or UI copy.
- Commit from inside the devenv environment (direnv loaded in the worktree). Verify each commit with `git show --stat`.

## File Structure

Create:
- `lib/mydia/downloads/built_in.ex`: public facade (`enabled?/0`, `client_configs/0`, `child_spec`), reads persistent_term.
- `lib/mydia/downloads/built_in/config.ex`: pure env parsing and auto-enable rule.
- `lib/mydia/downloads/built_in/status.ex`: state holder, PubSub broadcast, reason descriptions.
- `lib/mydia/downloads/built_in/engine.ex`: rqbit child process supervision.
- `lib/mydia/downloads/built_in/gluetun_client.ex`: Req client for gluetun's control API.
- `lib/mydia/downloads/built_in/vpn.ex`: poller that gates the engine on gluetun.
- `lib/mydia/downloads/built_in/leak_check.ex`: compares public IPs.
- `lib/mydia/downloads/built_in/supervisor.ex`: starts the above.
- `lib/mydia_web/live/admin_download_clients_live/built_in_components.ex`: status panel.
- `metadata-relay` route `GET /ip` in `metadata-relay/lib/metadata_relay/router.ex`.
- `vendor/gluetun/VERSION`, `vendor/gluetun/README.md`, `vendor/gluetun/patches/0001-split-tunnel.patch`.
- `docker/vpn-preflight.sh`: entrypoint helper.
- Tests mirroring each module under `test/mydia/downloads/built_in/`, plus `test/mydia_web/live/admin_download_clients_live/built_in_test.exs` and `metadata-relay/test/metadata_relay/ip_route_test.exs`.

Modify:
- `lib/mydia/settings/runtime_config.ex` (`get_runtime_download_clients/0`): append built-in client.
- `lib/mydia/downloads/client/rqbit.ex`: readiness guard for managed configs.
- `lib/mydia/application.ex`: start the supervisor.
- `lib/mydia_web/live/admin_download_clients_live/index.ex`, `index.html.heex`, `components.ex`: panel, PubSub, restart event.
- `Dockerfile`, `docker-entrypoint-prod.sh`, `devenv.nix`.
- Docs: `docs/using/reference/environment-variables.md`, `docs/using/reference/download-clients.md`, `lib/mydia/downloads/README.md`.

---

### Task 1: Config parsing and auto-enable rule

**Files:**
- Create: `lib/mydia/downloads/built_in/config.ex`
- Test: `test/mydia/downloads/built_in/config_test.exs`

**Interfaces:**
- Produces: `%Mydia.Downloads.BuiltIn.Config{enabled?: boolean, download_path: String.t, port: pos_integer, vpn?: boolean, vpn_provider: String.t | nil, vpn_interface: String.t, gluetun_dir: String.t, state_dir: String.t, warnings: [term]}` and `Config.load(env :: %{String.t => String.t}, other_client_types :: [atom]) :: Config.t`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Mydia.Downloads.BuiltIn.ConfigTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.BuiltIn.Config

  describe "load/2 auto-enable" do
    test "is on when no torrent client is configured" do
      assert %Config{enabled?: true} = Config.load(%{}, [:sabnzbd])
    end

    test "is off when a torrent client is configured" do
      for type <- [:qbittorrent, :transmission, :rqbit, :rtorrent] do
        assert %Config{enabled?: false} = Config.load(%{}, [type])
      end
    end

    test "MYDIA_TORRENT_ENABLED forces either way" do
      assert %Config{enabled?: true} =
               Config.load(%{"MYDIA_TORRENT_ENABLED" => "true"}, [:qbittorrent])

      assert %Config{enabled?: false} = Config.load(%{"MYDIA_TORRENT_ENABLED" => "false"}, [])
    end
  end

  describe "load/2 values" do
    test "defaults" do
      config = Config.load(%{}, [])
      assert config.download_path == "/data/downloads"
      assert config.port == 51413
      assert config.vpn? == false
      assert config.vpn_interface == "tun0"
      assert config.state_dir == "/config/rqbit"
      assert config.gluetun_dir == "/config/gluetun"
      assert config.warnings == []
    end

    test "reads path, port and provider" do
      config =
        Config.load(
          %{
            "MYDIA_TORRENT_DOWNLOAD_PATH" => "/downloads",
            "MYDIA_TORRENT_PORT" => "6881",
            "MYDIA_VPN_SERVICE_PROVIDER" => "protonvpn",
            "MYDIA_VPN_VPN_INTERFACE" => "wg0"
          },
          []
        )

      assert config.download_path == "/downloads"
      assert config.port == 6881
      assert config.vpn?
      assert config.vpn_provider == "protonvpn"
      assert config.vpn_interface == "wg0"
    end

    test "a bad port falls back to the default with a warning" do
      config = Config.load(%{"MYDIA_TORRENT_PORT" => "nope"}, [])
      assert config.port == 51413
      assert {:invalid_port, "nope"} in config.warnings
    end

    test "reserved gluetun variables are reported" do
      config =
        Config.load(
          %{"MYDIA_VPN_SERVICE_PROVIDER" => "pia", "MYDIA_VPN_SPLIT_TUNNEL_GID" => "5"},
          []
        )

      assert {:reserved_variable, "SPLIT_TUNNEL_GID"} in config.warnings
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./dev mix test test/mydia/downloads/built_in/config_test.exs`
Expected: FAIL, `Mydia.Downloads.BuiltIn.Config.__struct__/1 is undefined`.

- [ ] **Step 3: Write the implementation**

```elixir
defmodule Mydia.Downloads.BuiltIn.Config do
  @moduledoc """
  Reads the built-in torrent client's environment variables.

  Pure: callers pass the environment and the types of the other configured
  download clients, so tests never touch global env.
  """

  @torrent_types [:qbittorrent, :transmission, :rqbit, :rtorrent]
  @reserved ~w(SPLIT_TUNNEL_GID HTTP_CONTROL_SERVER_ADDRESS HTTP_CONTROL_SERVER_AUTH_DEFAULT_ROLE DNS_ADDRESS)
  @default_port 51413

  @type t :: %__MODULE__{
          enabled?: boolean(),
          download_path: String.t(),
          port: pos_integer(),
          vpn?: boolean(),
          vpn_provider: String.t() | nil,
          vpn_interface: String.t(),
          state_dir: String.t(),
          gluetun_dir: String.t(),
          warnings: [term()]
        }

  defstruct enabled?: false,
            download_path: "/data/downloads",
            port: @default_port,
            vpn?: false,
            vpn_provider: nil,
            vpn_interface: "tun0",
            state_dir: "/config/rqbit",
            gluetun_dir: "/config/gluetun",
            warnings: []

  @spec load(%{String.t() => String.t()}, [atom()]) :: t()
  def load(env, other_client_types) do
    {port, port_warnings} = parse_port(env["MYDIA_TORRENT_PORT"])
    provider = blank_to_nil(env["MYDIA_VPN_SERVICE_PROVIDER"])

    %__MODULE__{
      enabled?: enabled?(env["MYDIA_TORRENT_ENABLED"], other_client_types),
      download_path: env["MYDIA_TORRENT_DOWNLOAD_PATH"] || "/data/downloads",
      port: port,
      vpn?: provider != nil,
      vpn_provider: provider,
      vpn_interface: env["MYDIA_VPN_VPN_INTERFACE"] || "tun0",
      warnings: port_warnings ++ reserved_warnings(env)
    }
  end

  defp enabled?("true", _types), do: true
  defp enabled?("false", _types), do: false
  defp enabled?(_unset, types), do: not Enum.any?(types, &(&1 in @torrent_types))

  defp parse_port(nil), do: {@default_port, []}

  defp parse_port(value) do
    case Integer.parse(value) do
      {port, ""} when port in 1..65_535 -> {port, []}
      _ -> {@default_port, [{:invalid_port, value}]}
    end
  end

  defp reserved_warnings(env) do
    for name <- @reserved, Map.has_key?(env, "MYDIA_VPN_" <> name),
        do: {:reserved_variable, name}
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value), do: if(String.trim(value) == "", do: nil, else: value)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./dev mix test test/mydia/downloads/built_in/config_test.exs`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/mydia/downloads/built_in/config.ex test/mydia/downloads/built_in/config_test.exs
git commit -m "feat(downloads): built-in torrent client config"
```

---

### Task 2: Status holder and reason descriptions

**Files:**
- Create: `lib/mydia/downloads/built_in/status.ex`
- Test: `test/mydia/downloads/built_in/status_test.exs`

**Interfaces:**
- Produces:
  - `Status.start_link(opts)` with `opts[:name]` (default `Status`) and `opts[:warnings]` (default `[]`).
  - `Status.get(server \\ Status) :: %Status{engine: engine_state, vpn: vpn_state, port: port_state, warnings: [term]}`
    - `engine_state`: `:disabled | :starting | :running | {:stopped, reason} | {:crashed, reason, restarts}`
    - `vpn_state`: `:off | :connecting | {:up, %{provider: String.t, public_ip: String.t | nil}} | {:down, reason}`
    - `port_state`: `{:static, n} | {:forwarded, n, DateTime.t} | {:failed, reason, last_port}`
  - `Status.put(server \\ Status, part :: :engine | :vpn | :port | :warnings, value) :: :ok`, broadcasts `{:built_in_status, %Status{}}` on topic `Status.topic()` (`"built_in_torrent:status"`).
  - `Status.blocking_reason(status) :: nil | reason`: nil only when the engine is `:running`.
  - `Status.describe(reason) :: String.t`: the user-facing message with fix text.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Mydia.Downloads.BuiltIn.StatusTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.BuiltIn.Status

  setup do
    name = :"status_#{System.unique_integer([:positive])}"
    start_supervised!({Status, name: name})
    Phoenix.PubSub.subscribe(Mydia.PubSub, Status.topic())
    %{name: name}
  end

  test "starts with the engine starting and the VPN off", %{name: name} do
    assert %Status{engine: :starting, vpn: :off, port: nil, warnings: []} = Status.get(name)
  end

  test "carries config warnings from start" do
    name = :"status_w_#{System.unique_integer([:positive])}"
    start_supervised!({Status, name: name, warnings: [{:invalid_port, "x"}]}, id: name)
    assert %Status{warnings: [{:invalid_port, "x"}]} = Status.get(name)
  end

  test "put/3 stores and broadcasts", %{name: name} do
    :ok = Status.put(name, :vpn, {:down, :missing_net_admin})
    assert %Status{vpn: {:down, :missing_net_admin}} = Status.get(name)
    assert_receive {:built_in_status, %Status{vpn: {:down, :missing_net_admin}}}
  end

  describe "blocking_reason/1" do
    test "nil when the engine is running" do
      assert Status.blocking_reason(%Status{engine: :running}) == nil
    end

    test "the VPN reason wins over the engine's when the VPN is down" do
      status = %Status{engine: {:stopped, :vpn_down}, vpn: {:down, :missing_tun}}
      assert Status.blocking_reason(status) == :missing_tun
    end

    test "the engine reason otherwise" do
      assert Status.blocking_reason(%Status{engine: {:crashed, {:engine_exit, 1}, 5}}) ==
               {:engine_exit, 1}

      assert Status.blocking_reason(%Status{engine: :starting}) == :engine_starting
    end
  end

  describe "describe/1" do
    test "every reason has fix text" do
      reasons = [
        :missing_net_admin,
        :missing_tun,
        {:reserved_variable, "DNS_ADDRESS"},
        {:invalid_port, "x"},
        {:vpn_auth_failed, "bad credentials"},
        :vpn_down,
        {:vpn_down, "last log line"},
        :vpn_unreachable,
        :leak_detected,
        {:leak_check_failed, "timeout"},
        {:port_forward_failed, "no port"},
        {:engine_exit, 101},
        :engine_starting,
        :rqbit_not_found
      ]

      for reason <- reasons do
        message = Status.describe(reason)
        assert is_binary(message) and message != "", inspect(reason)
        refute message =~ "—"
      end

      assert Status.describe(:missing_net_admin) =~ "cap_add"
      assert Status.describe(:missing_tun) =~ "/dev/net/tun"
      assert Status.describe({:reserved_variable, "DNS_ADDRESS"}) =~ "MYDIA_VPN_DNS_ADDRESS"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./dev mix test test/mydia/downloads/built_in/status_test.exs`
Expected: FAIL, module undefined.

- [ ] **Step 3: Write the implementation**

```elixir
defmodule Mydia.Downloads.BuiltIn.Status do
  @moduledoc """
  The built-in torrent client's combined state: engine, VPN and listen port.

  Every change is broadcast so the admin page updates live. The `Rqbit`
  adapter and `ClientHealth` read `blocking_reason/1`, so a stopped engine
  surfaces as a named reason instead of a connection timeout.
  """

  use Agent

  @topic "built_in_torrent:status"

  defstruct engine: :starting, vpn: :off, port: nil, warnings: []

  @type t :: %__MODULE__{}

  def topic, do: @topic

  # opts: :name, and :warnings (Config.warnings, shown on the admin panel).
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    warnings = Keyword.get(opts, :warnings, [])
    Agent.start_link(fn -> %__MODULE__{warnings: warnings} end, name: name)
  end

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @spec get(GenServer.server()) :: t()
  def get(server \\ __MODULE__), do: Agent.get(server, & &1)

  @spec put(GenServer.server(), :engine | :vpn | :port | :warnings, term()) :: :ok
  def put(server \\ __MODULE__, part, value) do
    status = Agent.get_and_update(server, &(Map.put(&1, part, value) |> then(fn s -> {s, s} end)))
    Phoenix.PubSub.broadcast(Mydia.PubSub, @topic, {:built_in_status, status})
    :ok
  end

  @spec blocking_reason(t()) :: nil | term()
  def blocking_reason(%__MODULE__{engine: :running}), do: nil
  def blocking_reason(%__MODULE__{vpn: {:down, reason}}), do: reason
  def blocking_reason(%__MODULE__{engine: {:stopped, reason}}), do: reason
  def blocking_reason(%__MODULE__{engine: {:crashed, reason, _}}), do: reason
  def blocking_reason(%__MODULE__{engine: :disabled}), do: :engine_disabled
  def blocking_reason(%__MODULE__{}), do: :engine_starting

  @spec describe(term()) :: String.t()
  def describe(:missing_net_admin),
    do: "The VPN needs the NET_ADMIN capability. Add cap_add: [NET_ADMIN] to the Mydia container."

  def describe(:missing_tun),
    do: "The VPN needs the TUN device. Add devices: [/dev/net/tun] to the Mydia container."

  def describe({:reserved_variable, name}),
    do: "MYDIA_VPN_#{name} is set by Mydia itself. Remove it from the container environment."

  def describe({:invalid_port, value}),
    do: "MYDIA_TORRENT_PORT is #{inspect(value)}, not a port number. Using 51413."

  def describe({:vpn_auth_failed, message}),
    do: "The VPN provider rejected the login: #{message}. Check the MYDIA_VPN_ credentials."

  def describe(:vpn_down), do: "The VPN tunnel is down. Torrents are stopped until it returns."

  def describe({:vpn_down, last_log}),
    do: "The VPN tunnel is down. Torrents are stopped until it returns. Last VPN log: #{last_log}"

  def describe(:vpn_unreachable),
    do: "The VPN service is not answering. Torrents are stopped until it does."

  def describe(:leak_detected),
    do:
      "Torrent traffic was not going through the VPN. Torrents will not start until the VPN is fixed."

  def describe({:leak_check_failed, message}),
    do: "Could not confirm torrent traffic goes through the VPN (#{message}). Torrents are stopped."

  def describe({:port_forward_failed, message}),
    do:
      "Port forwarding failed (#{message}). Torrents keep running on the last port; seeding is limited to outgoing connections."

  def describe({:engine_exit, code}), do: "The torrent engine exited with code #{code}."
  def describe(:engine_starting), do: "The torrent engine is starting."
  def describe(:engine_disabled), do: "The built-in torrent client is disabled."

  def describe(:rqbit_not_found),
    do: "The rqbit binary is missing from this installation."

  def describe(other), do: "Built-in torrent client error: #{inspect(other)}"
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./dev mix test test/mydia/downloads/built_in/status_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/mydia/downloads/built_in/status.ex test/mydia/downloads/built_in/status_test.exs
git commit -m "feat(downloads): built-in torrent client status and reasons"
```

---

### Task 3: Engine supervision of the rqbit child

**Files:**
- Create: `lib/mydia/downloads/built_in/engine.ex`
- Test: `test/mydia/downloads/built_in/engine_test.exs`
- Test fixture: `test/support/fixtures/fake_rqbit.sh` (executable)

**Interfaces:**
- Consumes: `Config` (Task 1), `Status.put/3` (Task 2).
- Produces:
  - `Engine.start_link(opts)`: opts `:config` (`Config.t`), `:status` (Status server, default `Status`), `:name` (default `Engine`), `:rqbit_path` (default `"rqbit"`), `:api_port` (default `3030`), `:credentials` (`{user, pass}`), `:autostart` (boolean: start immediately with `config.port`; true when the VPN is off), `:backoff_ms` (default `2_000`).
  - `Engine.start_engine(server \\ Engine, listen_port) :: :ok`: starts, or restarts when the port differs.
  - `Engine.stop_engine(server \\ Engine, reason) :: :ok`
  - `Engine.restart(server \\ Engine) :: :ok`: clears the crash counter and starts again.
  - `Engine.args(config, api_port, listen_port) :: [String.t]` (public for tests).

- [ ] **Step 1: Write the fake rqbit fixture**

`test/support/fixtures/fake_rqbit.sh`:

```sh
#!/bin/sh
# Stands in for rqbit in Engine tests. Records its arguments and the basic
# auth variable, then behaves as FAKE_RQBIT_MODE says.
printf '%s\n' "$@" > "$FAKE_RQBIT_ARGS"
printf '%s\n' "$RQBIT_HTTP_BASIC_AUTH_USERPASS" >> "$FAKE_RQBIT_ARGS"
case "$FAKE_RQBIT_MODE" in
  exit) exit 3 ;;
  *) exec sleep 600 ;;
esac
```

Run: `chmod +x test/support/fixtures/fake_rqbit.sh`

- [ ] **Step 2: Write the failing test**

```elixir
defmodule Mydia.Downloads.BuiltIn.EngineTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.BuiltIn.{Config, Engine, Status}

  @fake Path.expand("../../../support/fixtures/fake_rqbit.sh", __DIR__)

  setup %{tmp_dir: tmp_dir} = ctx do
    status = :"status_#{System.unique_integer([:positive])}"
    start_supervised!({Status, name: status})
    Phoenix.PubSub.subscribe(Mydia.PubSub, Status.topic())

    config = %Config{
      enabled?: true,
      download_path: Path.join(tmp_dir, "downloads"),
      state_dir: Path.join(tmp_dir, "rqbit"),
      vpn?: Map.get(ctx, :vpn, false),
      vpn_interface: "tun0"
    }

    args_file = Path.join(tmp_dir, "args")
    %{status: status, config: config, args_file: args_file}
  end

  defp start_engine(ctx, extra) do
    name = :"engine_#{System.unique_integer([:positive])}"

    opts =
      [
        name: name,
        config: ctx.config,
        status: ctx.status,
        rqbit_path: @fake,
        credentials: {"mydia", "secret"},
        backoff_ms: 10,
        env: [
          {"FAKE_RQBIT_ARGS", ctx.args_file},
          {"FAKE_RQBIT_MODE", Keyword.get(extra, :mode, "run")}
        ]
      ] ++ Keyword.drop(extra, [:mode])

    start_supervised!({Engine, opts}, id: name)
    name
  end

  @tag :tmp_dir
  test "args put global flags before server start", ctx do
    args = Engine.args(ctx.config, 3030, 6881)

    assert args == [
             "--http-api-listen-addr",
             "127.0.0.1:3030",
             "--listen-port",
             "6881",
             "--disable-upnp-port-forward",
             "server",
             "start",
             "--persistence-location",
             ctx.config.state_dir,
             ctx.config.download_path
           ]
  end

  @tag :tmp_dir
  @tag vpn: true
  test "args bind to the tunnel when the VPN is on", ctx do
    args = Engine.args(ctx.config, 3030, 6881)
    assert ["--bind-device", "tun0"] == Enum.slice(args, 5, 2)
  end

  @tag :tmp_dir
  test "autostart runs rqbit with credentials and reports running", ctx do
    start_engine(ctx, autostart: true)
    assert_receive {:built_in_status, %Status{engine: :running, port: {:static, 51413}}}, 1_000
    Process.sleep(50)
    lines = File.read!(ctx.args_file) |> String.split("\n", trim: true)
    assert "51413" in lines
    assert List.last(lines) == "mydia:secret"
  end

  @tag :tmp_dir
  test "stop_engine/2 kills the child and records the reason", ctx do
    name = start_engine(ctx, autostart: true)
    assert_receive {:built_in_status, %Status{engine: :running}}, 1_000
    :ok = Engine.stop_engine(name, :vpn_down)
    assert %Status{engine: {:stopped, :vpn_down}} = Status.get(ctx.status)
  end

  @tag :tmp_dir
  test "a child that keeps exiting ends crashed after 5 restarts", ctx do
    start_engine(ctx, autostart: true, mode: "exit")

    assert_receive {:built_in_status, %Status{engine: {:crashed, {:engine_exit, 3}, 5}}},
                   2_000
  end

  @tag :tmp_dir
  test "restart/1 clears a crash", ctx do
    name = start_engine(ctx, autostart: true, mode: "exit")
    assert_receive {:built_in_status, %Status{engine: {:crashed, _, 5}}}, 2_000
    :ok = Engine.restart(name)
    assert_receive {:built_in_status, %Status{engine: :running}}, 1_000
  end

  @tag :tmp_dir
  test "a missing binary is a named reason", ctx do
    start_engine(ctx, autostart: true, rqbit_path: "/nonexistent/rqbit")
    assert_receive {:built_in_status, %Status{engine: {:crashed, :rqbit_not_found, 0}}}, 1_000
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `./dev mix test test/mydia/downloads/built_in/engine_test.exs`
Expected: FAIL, module undefined.

- [ ] **Step 4: Write the implementation**

```elixir
defmodule Mydia.Downloads.BuiltIn.Engine do
  @moduledoc """
  Runs `rqbit server` as a child process and keeps it running.

  The child is opened as a Port and tracked by OS pid, like
  `Mydia.BoundedCommand`, so stopping it kills it rather than orphaning it.
  The pid is also written to `<state_dir>/rqbit.pid` so a child left behind by
  a crashed BEAM is killed on the next start.

  It restarts with backoff up to 5 times, then holds `:crashed` until
  `restart/1`. With the VPN on, the binary is installed setgid
  `mydia-torrent` in the image, which is what puts its traffic in the tunnel.
  """

  use GenServer
  require Logger

  alias Mydia.Downloads.BuiltIn.{Config, Status}

  @max_restarts 5

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  def start_engine(server \\ __MODULE__, listen_port),
    do: GenServer.call(server, {:start, listen_port})

  def stop_engine(server \\ __MODULE__, reason), do: GenServer.call(server, {:stop, reason})
  def restart(server \\ __MODULE__), do: GenServer.call(server, :restart)

  @spec args(Config.t(), pos_integer(), pos_integer()) :: [String.t()]
  def args(%Config{} = config, api_port, listen_port) do
    bind = if config.vpn?, do: ["--bind-device", config.vpn_interface], else: []

    ["--http-api-listen-addr", "127.0.0.1:#{api_port}", "--listen-port", "#{listen_port}"] ++
      ["--disable-upnp-port-forward"] ++
      bind ++
      ["server", "start", "--persistence-location", config.state_dir, config.download_path]
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    config = Keyword.fetch!(opts, :config)

    state = %{
      config: config,
      status: Keyword.get(opts, :status, Status),
      rqbit_path: Keyword.get(opts, :rqbit_path, "rqbit"),
      api_port: Keyword.get(opts, :api_port, 3030),
      credentials: Keyword.fetch!(opts, :credentials),
      backoff_ms: Keyword.get(opts, :backoff_ms, 2_000),
      env: Keyword.get(opts, :env, []),
      port: nil,
      os_pid: nil,
      listen_port: nil,
      restarts: 0
    }

    kill_stale(config.state_dir)

    if Keyword.get(opts, :autostart, false) do
      send(self(), {:autostart, config.port})
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:start, listen_port}, _from, %{port: nil} = state),
    do: {:reply, :ok, spawn_child(%{state | listen_port: listen_port})}

  def handle_call({:start, listen_port}, _from, %{listen_port: listen_port} = state),
    do: {:reply, :ok, state}

  def handle_call({:start, listen_port}, _from, state) do
    state = kill_child(state)
    {:reply, :ok, spawn_child(%{state | listen_port: listen_port})}
  end

  def handle_call({:stop, reason}, _from, state) do
    state = kill_child(state)
    Status.put(state.status, :engine, {:stopped, reason})
    {:reply, :ok, state}
  end

  def handle_call(:restart, _from, state) do
    state = kill_child(%{state | restarts: 0})
    {:reply, :ok, spawn_child(state)}
  end

  @impl true
  def handle_info({:autostart, port}, state) do
    Status.put(state.status, :port, {:static, port})
    {:noreply, spawn_child(%{state | listen_port: port})}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    Logger.debug("rqbit: " <> String.trim_trailing(data))
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.error("rqbit exited with code #{code}")
    state = %{state | port: nil, os_pid: nil}

    if state.restarts >= @max_restarts do
      Status.put(state.status, :engine, {:crashed, {:engine_exit, code}, state.restarts})
      {:noreply, state}
    else
      delay = state.backoff_ms * Integer.pow(2, state.restarts)
      Process.send_after(self(), :respawn, delay)
      {:noreply, %{state | restarts: state.restarts + 1}}
    end
  end

  def handle_info(:respawn, %{port: nil} = state), do: {:noreply, spawn_child(state)}
  def handle_info(:respawn, state), do: {:noreply, state}
  def handle_info({:EXIT, _port, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: kill_child(state)

  defp spawn_child(state) do
    case System.find_executable(state.rqbit_path) do
      nil ->
        Status.put(state.status, :engine, {:crashed, :rqbit_not_found, 0})
        state

      path ->
        File.mkdir_p!(state.config.state_dir)
        File.mkdir_p!(state.config.download_path)
        {user, pass} = state.credentials

        env =
          [{"RQBIT_HTTP_BASIC_AUTH_USERPASS", "#{user}:#{pass}"} | state.env]
          |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

        port =
          Port.open({:spawn_executable, path}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            :hide,
            args: args(state.config, state.api_port, state.listen_port),
            env: env
          ])

        {:os_pid, os_pid} = Port.info(port, :os_pid)
        File.write!(pid_file(state.config.state_dir), Integer.to_string(os_pid))
        Status.put(state.status, :engine, :running)
        %{state | port: port, os_pid: os_pid}
    end
  end

  defp kill_child(%{port: nil} = state), do: state

  defp kill_child(state) do
    Port.close(state.port)
    System.cmd("kill", ["-TERM", Integer.to_string(state.os_pid)], stderr_to_stdout: true)
    File.rm(pid_file(state.config.state_dir))
    %{state | port: nil, os_pid: nil}
  rescue
    ArgumentError -> %{state | port: nil, os_pid: nil}
  end

  defp kill_stale(state_dir) do
    with {:ok, contents} <- File.read(pid_file(state_dir)),
         {pid, ""} <- Integer.parse(String.trim(contents)),
         {:ok, cmdline} <- File.read("/proc/#{pid}/cmdline"),
         true <- String.contains?(cmdline, "rqbit") do
      System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
    end

    File.rm(pid_file(state_dir))
  end

  defp pid_file(state_dir), do: Path.join(state_dir, "rqbit.pid")
end
```

Note: `:running` is set when the process spawns. rqbit binds its API within a second; a grab in that window gets a connection error from the adapter, which is the same failure an external client has during its own start.

- [ ] **Step 5: Run test to verify it passes**

Run: `./dev mix test test/mydia/downloads/built_in/engine_test.exs`
Expected: PASS (7 tests). If the crash test is slow, check that `backoff_ms: 10` reached `init/1`.

- [ ] **Step 6: Commit**

```bash
git add lib/mydia/downloads/built_in/engine.ex test/mydia/downloads/built_in/engine_test.exs test/support/fixtures/fake_rqbit.sh
git commit -m "feat(downloads): supervise the built-in rqbit engine"
```

---

### Task 4: Register the built-in client and guard the adapter

**Files:**
- Create: `lib/mydia/downloads/built_in.ex`
- Modify: `lib/mydia/settings/runtime_config.ex:256-265` (`get_runtime_download_clients/0`)
- Modify: `lib/mydia/downloads/client/rqbit.ex` (every `@impl true` callback that issues a request)
- Test: `test/mydia/downloads/built_in_test.exs`, add to `test/mydia/downloads/client/rqbit_test.exs`

**Interfaces:**
- Consumes: `Status.get/1`, `Status.blocking_reason/1`, `Status.describe/1`.
- Produces:
  - `BuiltIn.put_runtime(%{api_port: integer, credentials: {user, pass}, config: Config.t})`: stores in `:persistent_term` key `{Mydia.Downloads.BuiltIn, :runtime}`.
  - `BuiltIn.client_configs() :: [%DownloadClientConfig{}]`: `[]` when not running.
  - `BuiltIn.managed?(client_config_map) :: boolean`.
  - `BuiltIn.guard(client_config_map, status_server \\ Status) :: :ok | {:error, Error.t}`.
  - The client's name is `"Built-in"`, id `runtime::download_client::Built-in`, `connection_settings: %{"managed" => true}`.

- [ ] **Step 1: Write the failing tests**

`test/mydia/downloads/built_in_test.exs`:

```elixir
defmodule Mydia.Downloads.BuiltInTest do
  use ExUnit.Case, async: false

  alias Mydia.Downloads.BuiltIn
  alias Mydia.Downloads.BuiltIn.{Config, Status}
  alias Mydia.Settings.DownloadClientConfig

  setup do
    on_exit(fn -> BuiltIn.clear_runtime() end)
    :ok
  end

  test "no client before the engine is set up" do
    assert BuiltIn.client_configs() == []
  end

  test "client_configs/0 describes the local engine" do
    BuiltIn.put_runtime(%{
      api_port: 3030,
      credentials: {"mydia", "s3cret"},
      config: %Config{download_path: "/data/downloads"}
    })

    assert [%DownloadClientConfig{} = client] = BuiltIn.client_configs()
    assert client.name == "Built-in"
    assert client.id == "runtime::download_client::Built-in"
    assert client.type == :rqbit
    assert client.host == "127.0.0.1"
    assert client.port == 3030
    assert client.username == "mydia"
    assert client.password == "s3cret"
    assert client.download_directory == "/data/downloads"
    assert client.connection_settings == %{"managed" => true}
    assert BuiltIn.managed?(%{options: client.connection_settings})
  end

  test "guard/2 passes unmanaged configs through" do
    assert BuiltIn.guard(%{options: %{}}) == :ok
  end

  test "guard/2 returns the blocking reason for a managed config" do
    name = :"status_#{System.unique_integer([:positive])}"
    start_supervised!({Status, name: name})
    Status.put(name, :vpn, {:down, :missing_net_admin})

    assert {:error, %{message: message}} = BuiltIn.guard(%{options: %{"managed" => true}}, name)
    assert message =~ "cap_add"

    Status.put(name, :vpn, {:up, %{provider: "protonvpn", public_ip: "203.0.113.9"}})
    Status.put(name, :engine, :running)
    assert BuiltIn.guard(%{options: %{"managed" => true}}, name) == :ok
  end
end
```

Add to `test/mydia/downloads/client/rqbit_test.exs`, inside the module, a new describe:

```elixir
  describe "managed built-in config" do
    test "returns the built-in status reason instead of calling rqbit" do
      start_supervised!({Mydia.Downloads.BuiltIn.Status, name: Mydia.Downloads.BuiltIn.Status})
      Mydia.Downloads.BuiltIn.Status.put(:engine, {:stopped, :vpn_down})

      config = %{
        type: :rqbit,
        host: "127.0.0.1",
        port: 1,
        options: %{"managed" => true},
        connection_settings: %{"managed" => true}
      }

      assert {:error, %{message: message}} = Mydia.Downloads.Client.Rqbit.test_connection(config)
      assert message =~ "VPN tunnel is down"
    end
  end
```

If `rqbit_test.exs` is `async: true`, put this describe in a new file `test/mydia/downloads/client/rqbit_managed_test.exs` with `async: false` instead, because it starts the globally named `Status`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `./dev mix test test/mydia/downloads/built_in_test.exs test/mydia/downloads/client/rqbit_test.exs`
Expected: FAIL, `BuiltIn` undefined.

- [ ] **Step 3: Write `lib/mydia/downloads/built_in.ex`**

```elixir
defmodule Mydia.Downloads.BuiltIn do
  @moduledoc """
  Facade for the built-in torrent client.

  The supervisor stores the engine's address and credentials with
  `put_runtime/1`; `Mydia.Settings.RuntimeConfig.get_runtime_download_clients/0`
  appends `client_configs/0`, so the rest of Mydia sees an ordinary runtime
  client of type `rqbit` driven by `Mydia.Downloads.Client.Rqbit`.
  """

  alias Mydia.Downloads.BuiltIn.Status
  alias Mydia.Downloads.Client.Error
  alias Mydia.Settings.DownloadClientConfig
  alias Mydia.Settings.RuntimeConfig

  @key {__MODULE__, :runtime}
  @name "Built-in"

  def put_runtime(runtime), do: :persistent_term.put(@key, runtime)
  def clear_runtime, do: :persistent_term.erase(@key)
  def runtime, do: :persistent_term.get(@key, nil)

  @spec client_configs() :: [DownloadClientConfig.t()]
  def client_configs do
    case runtime() do
      nil ->
        []

      %{api_port: port, credentials: {user, pass}, config: config} ->
        [
          %DownloadClientConfig{
            id: RuntimeConfig.build_runtime_id(:download_client, @name),
            name: @name,
            type: :rqbit,
            enabled: true,
            priority: 10,
            host: "127.0.0.1",
            port: port,
            use_ssl: false,
            username: user,
            password: pass,
            download_directory: config.download_path,
            connection_settings: %{"managed" => true},
            external_torrents: :auto
          }
        ]
    end
  end

  @spec managed?(map()) :: boolean()
  def managed?(config) do
    options = Map.get(config, :options) || Map.get(config, :connection_settings) || %{}
    Map.get(options, "managed") == true or Map.get(options, :managed) == true
  end

  @spec guard(map(), GenServer.server()) :: :ok | {:error, Error.t()}
  def guard(config, status_server \\ Status) do
    with true <- managed?(config),
         reason when not is_nil(reason) <- Status.blocking_reason(Status.get(status_server)) do
      {:error, Error.connection_failed(Status.describe(reason), %{built_in: reason})}
    else
      _ -> :ok
    end
  catch
    :exit, _ -> {:error, Error.connection_failed(Status.describe(:engine_starting))}
  end
end
```

- [ ] **Step 4: Append the built-in client in `RuntimeConfig`**

In `lib/mydia/settings/runtime_config.ex`, change `get_runtime_download_clients/0` to:

```elixir
  def get_runtime_download_clients do
    runtime_config = get_runtime_config()

    configured =
      if is_struct(runtime_config) and Map.has_key?(runtime_config, :download_clients) do
        Enum.map(runtime_config.download_clients, &map_to_download_client_config/1)
      else
        []
      end

    configured ++ Mydia.Downloads.BuiltIn.client_configs()
  end
```

`build_runtime_id/2` is already public in this module.

- [ ] **Step 5: Guard the adapter**

In `lib/mydia/downloads/client/rqbit.ex`, add near the top of the module:

```elixir
  alias Mydia.Downloads.BuiltIn

  # A managed (built-in) config reports why the engine is not running instead
  # of a connection error to 127.0.0.1.
  defp guarded(config, fun) do
    case BuiltIn.guard(config) do
      :ok -> fun.()
      {:error, _} = error -> error
    end
  end
```

Wrap the body of each request-issuing callback: `test_connection/1`, `add_torrent/3`, `get_status/2`, `list_torrents/2`, `remove_torrent/3`, `pause_torrent/2`, `resume_torrent/2`, `list_files/2`. For example:

```elixir
  @impl true
  def test_connection(config) do
    guarded(config, fn ->
      req = HTTP.new_request(config)

      case HTTP.get(req, "/torrents") do
        {:ok, %{status: status}} when status in 200..299 ->
          {:ok, ClientInfo.new(version: "rqbit")}

        {:ok, response} ->
          {:error, api_error_from(response)}

        {:error, _} = error ->
          error
      end
    end)
  end
```

Leave `supported_protocols/0` and any pure helpers unwrapped. `ClientHealth.do_health_check/1` calls `test_connection/1`, so the reason reaches the health badge with no `ClientHealth` change.

- [ ] **Step 6: Run tests to verify they pass**

Run: `./dev mix test test/mydia/downloads/built_in_test.exs test/mydia/downloads/client/ test/mydia/settings/`
Expected: PASS, and the existing rqbit adapter tests unchanged and green.

- [ ] **Step 7: Commit**

```bash
git add lib/mydia/downloads/built_in.ex lib/mydia/settings/runtime_config.ex lib/mydia/downloads/client/rqbit.ex test/mydia/downloads/built_in_test.exs test/mydia/downloads/client/
git commit -m "feat(downloads): register the built-in client and surface its status"
```

---

### Task 5: Relay IP echo endpoint

**Files:**
- Modify: `metadata-relay/lib/metadata_relay/router.ex` (after the `/client-config` route)
- Test: `metadata-relay/test/metadata_relay/ip_route_test.exs`

**Interfaces:**
- Produces: `GET /ip` → `200 {"ip": "<caller ip>"}`, `cache-control: no-store`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule MetadataRelay.IpRouteTest do
  use ExUnit.Case, async: true

  alias MetadataRelay.Router

  test "GET /ip returns the caller's address and is never cached" do
    conn =
      Plug.Test.conn(:get, "/ip")
      |> Map.put(:remote_ip, {198, 51, 100, 7})
      |> Router.call(Router.init([]))

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"ip" => "198.51.100.7"}
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd metadata-relay && mix test test/metadata_relay/ip_route_test.exs`
Expected: FAIL with status 404.

- [ ] **Step 3: Add the route**

```elixir
  # The caller's public address, as the relay sees it. Mydia's built-in
  # torrent client compares the address its torrent traffic leaves from with
  # Mydia's own to prove the VPN is in the path.
  get "/ip" do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, Jason.encode!(%{ip: MetadataRelay.ClientIp.resolve(conn)}))
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd metadata-relay && mix test test/metadata_relay/ip_route_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add metadata-relay/lib/metadata_relay/router.ex metadata-relay/test/metadata_relay/ip_route_test.exs
git commit -m "feat(relay): add an IP echo endpoint"
```

---

### Task 6: Gluetun control client and leak check

**Files:**
- Create: `lib/mydia/downloads/built_in/gluetun_client.ex`, `lib/mydia/downloads/built_in/leak_check.ex`
- Test: `test/mydia/downloads/built_in/gluetun_client_test.exs`, `test/mydia/downloads/built_in/leak_check_test.exs`

**Interfaces:**
- Produces:
  - `GluetunClient.new(base_url :: String.t, api_key :: String.t) :: Req.Request.t`
  - `GluetunClient.vpn_status(req) :: {:ok, String.t} | {:error, term}`: `"running"`, `"stopped"`, ...
  - `GluetunClient.public_ip(req) :: {:ok, String.t | nil} | {:error, term}`
  - `GluetunClient.forwarded_port(req) :: {:ok, non_neg_integer} | {:error, term}`: 0 when none.
  - `LeakCheck.run(opts) :: :ok | {:error, :leak_detected | {:leak_check_failed, String.t}}`, where opts are `:relay_url`, `:torrent_ip_fun` (`(url -> {:ok, ip} | {:error, msg})`, default runs `torrent-curl`) and `:mydia_ip_fun` (default `Req`).

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Mydia.Downloads.BuiltIn.GluetunClientTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.BuiltIn.GluetunClient

  setup do
    bypass = Bypass.open()
    %{bypass: bypass, req: GluetunClient.new("http://localhost:#{bypass.port}", "k3y")}
  end

  test "vpn_status sends the API key", %{bypass: bypass, req: req} do
    Bypass.expect_once(bypass, "GET", "/v1/vpn/status", fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["k3y"]
      Plug.Conn.resp(conn, 200, ~s({"status":"running"}))
    end)

    assert GluetunClient.vpn_status(req) == {:ok, "running"}
  end

  test "public_ip", %{bypass: bypass, req: req} do
    Bypass.expect_once(bypass, "GET", "/v1/publicip/ip", fn conn ->
      Plug.Conn.resp(conn, 200, ~s({"public_ip":"203.0.113.9","country":"Nowhere"}))
    end)

    assert GluetunClient.public_ip(req) == {:ok, "203.0.113.9"}
  end

  test "forwarded_port is 0 when none", %{bypass: bypass, req: req} do
    Bypass.expect_once(bypass, "GET", "/v1/portforward", fn conn ->
      Plug.Conn.resp(conn, 200, ~s({"port":0}))
    end)

    assert GluetunClient.forwarded_port(req) == {:ok, 0}
  end

  test "an unreachable server is an error", %{bypass: bypass, req: req} do
    Bypass.down(bypass)
    assert {:error, _} = GluetunClient.vpn_status(req)
  end
end
```

```elixir
defmodule Mydia.Downloads.BuiltIn.LeakCheckTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.BuiltIn.LeakCheck

  defp run(torrent, mydia) do
    LeakCheck.run(
      relay_url: "https://relay.invalid",
      torrent_ip_fun: fn "https://relay.invalid/ip" -> torrent end,
      mydia_ip_fun: fn "https://relay.invalid/ip" -> mydia end
    )
  end

  test "different addresses pass" do
    assert run({:ok, "203.0.113.9"}, {:ok, "198.51.100.7"}) == :ok
  end

  test "the same address is a leak" do
    assert run({:ok, "198.51.100.7"}, {:ok, "198.51.100.7"}) == {:error, :leak_detected}
  end

  test "a failed torrent-side request fails the check" do
    assert run({:error, "timeout"}, {:ok, "198.51.100.7"}) ==
             {:error, {:leak_check_failed, "timeout"}}
  end

  test "a failed Mydia-side request fails the check" do
    assert run({:ok, "203.0.113.9"}, {:error, "nxdomain"}) ==
             {:error, {:leak_check_failed, "nxdomain"}}
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./dev mix test test/mydia/downloads/built_in/gluetun_client_test.exs test/mydia/downloads/built_in/leak_check_test.exs`
Expected: FAIL, modules undefined.

- [ ] **Step 3: Write the implementations**

```elixir
defmodule Mydia.Downloads.BuiltIn.GluetunClient do
  @moduledoc "Reads gluetun's control server (`/v1/...`, `X-API-Key` auth)."

  def new(base_url, api_key) do
    Req.new(
      base_url: base_url,
      headers: [{"x-api-key", api_key}],
      retry: false,
      receive_timeout: 5_000,
      connect_options: [timeout: 2_000]
    )
  end

  def vpn_status(req), do: get(req, "/v1/vpn/status", "status")
  def public_ip(req), do: get(req, "/v1/publicip/ip", "public_ip")

  def forwarded_port(req) do
    case get(req, "/v1/portforward", "port") do
      {:ok, nil} -> {:ok, 0}
      other -> other
    end
  end

  defp get(req, path, key) do
    case Req.get(req, url: path) do
      {:ok, %Req.Response{status: 200, body: body}} -> field(body, key)
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, exception} -> {:error, Exception.message(exception)}
    end
  end

  # Gluetun encodes with json.Encoder and may not send a JSON content type, so
  # Req can hand back the raw string.
  defp field(%{} = body, key), do: {:ok, Map.get(body, key)}

  defp field(body, key) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> {:ok, Map.get(decoded, key)}
      _ -> {:error, :invalid_json}
    end
  end
end
```

```elixir
defmodule Mydia.Downloads.BuiltIn.LeakCheck do
  @moduledoc """
  Proves torrent traffic leaves through the VPN: the address the relay sees
  from the torrent group (`torrent-curl`, setgid `mydia-torrent`) must differ
  from the address it sees from Mydia itself.
  """

  def run(opts) do
    url = Keyword.fetch!(opts, :relay_url) <> "/ip"
    torrent_ip = Keyword.get(opts, :torrent_ip_fun, &torrent_ip/1)
    mydia_ip = Keyword.get(opts, :mydia_ip_fun, &mydia_ip/1)

    with {:ok, via_torrent} <- torrent_ip.(url),
         {:ok, via_mydia} <- mydia_ip.(url) do
      if via_torrent == via_mydia, do: {:error, :leak_detected}, else: :ok
    else
      {:error, message} -> {:error, {:leak_check_failed, message}}
    end
  end

  defp torrent_ip(url) do
    case Mydia.BoundedCommand.run("torrent-curl", ["-fsS", "--max-time", "10", url], 15_000) do
      {:ok, body} -> decode(body)
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp mydia_ip(url) do
    case Req.get(url, retry: false, receive_timeout: 10_000) do
      {:ok, %Req.Response{status: 200, body: %{"ip" => ip}}} -> {:ok, ip}
      {:ok, %Req.Response{status: status}} -> {:error, "relay answered #{status}"}
      {:error, exception} -> {:error, Exception.message(exception)}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{"ip" => ip}} -> {:ok, ip}
      _ -> {:error, "unexpected relay response"}
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./dev mix test test/mydia/downloads/built_in/gluetun_client_test.exs test/mydia/downloads/built_in/leak_check_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/mydia/downloads/built_in/gluetun_client.ex lib/mydia/downloads/built_in/leak_check.ex test/mydia/downloads/built_in/gluetun_client_test.exs test/mydia/downloads/built_in/leak_check_test.exs
git commit -m "feat(downloads): gluetun control client and VPN leak check"
```

---

### Task 7: The VPN gate

**Files:**
- Create: `lib/mydia/downloads/built_in/vpn.ex`
- Test: `test/mydia/downloads/built_in/vpn_test.exs`

**Interfaces:**
- Consumes: `Config`, `Status.put/3`, `Engine.start_engine/2`, `Engine.stop_engine/2`, `GluetunClient.*`, `LeakCheck.run/1`.
- Produces: `Vpn.start_link(opts)`, where opts are:
  - `:config`, `:status`, `:engine`, `:name`
  - `:base_url` (default `"http://127.0.0.1:8000"`)
  - `:interval_ms` (default `10_000`)
  - `:leak_check` (`(-> :ok | {:error, term})`, default `LeakCheck.run(relay_url: Mydia.Metadata.metadata_relay_url())`)

  Behaviour, on each poll:
  1. The preflight file names a problem: `vpn = {:down, reason}` and the engine is stopped.
  2. The API key file is missing, or gluetun is unreachable: `{:down, :vpn_unreachable}`, engine stopped.
  3. Status is not `"running"`: `{:down, {:vpn_down, last_log_line}}` (or `:vpn_down` when there is no log), engine stopped.
  4. Status is `"running"` and the previous state was not up: run the leak check. If it fails: `{:down, reason}`, engine stopped. If it passes: `{:up, ...}`.
  5. While up: forwarded port > 0 gives `port = {:forwarded, n, now}` and `Engine.start_engine(n)`; otherwise `{:static, config.port}` and `Engine.start_engine(config.port)`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Mydia.Downloads.BuiltIn.VpnTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.BuiltIn.{Config, Status, Vpn}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    bypass = Bypass.open()
    status = :"status_#{System.unique_integer([:positive])}"
    start_supervised!({Status, name: status})
    Phoenix.PubSub.subscribe(Mydia.PubSub, Status.topic())
    File.write!(Path.join(dir, "apikey"), "k3y")
    File.write!(Path.join(dir, "preflight"), "net_admin=ok\ntun=ok\n")

    config = %Config{vpn?: true, vpn_provider: "protonvpn", port: 51413, gluetun_dir: dir}
    %{bypass: bypass, status: status, config: config, dir: dir}
  end

  defp start_vpn(ctx, leak_result) do
    test_pid = self()

    engine_fun = fn
      {:start, port} -> send(test_pid, {:engine_start, port}) && :ok
      {:stop, reason} -> send(test_pid, {:engine_stop, reason}) && :ok
    end

    start_supervised!(
      {Vpn,
       name: :"vpn_#{System.unique_integer([:positive])}",
       config: ctx.config,
       status: ctx.status,
       engine_fun: engine_fun,
       base_url: "http://localhost:#{ctx.bypass.port}",
       interval_ms: 50,
       leak_check: fn -> leak_result end}
    )
  end

  defp gluetun(bypass, status, port) do
    Bypass.stub(bypass, "GET", "/v1/vpn/status", fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!(%{status: status}))
    end)

    Bypass.stub(bypass, "GET", "/v1/publicip/ip", fn conn ->
      Plug.Conn.resp(conn, 200, ~s({"public_ip":"203.0.113.9"}))
    end)

    Bypass.stub(bypass, "GET", "/v1/portforward", fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!(%{port: port}))
    end)
  end

  test "running VPN with a passed leak check starts the engine on the forwarded port", ctx do
    gluetun(ctx.bypass, "running", 40_123)
    start_vpn(ctx, :ok)

    assert_receive {:engine_start, 40_123}, 1_000
    assert %Status{vpn: {:up, %{provider: "protonvpn", public_ip: "203.0.113.9"}}} =
             Status.get(ctx.status)

    assert %Status{port: {:forwarded, 40_123, _}} = Status.get(ctx.status)
  end

  test "no forwarded port uses the configured port", ctx do
    gluetun(ctx.bypass, "running", 0)
    start_vpn(ctx, :ok)
    assert_receive {:engine_start, 51413}, 1_000
  end

  test "a failed leak check never starts the engine", ctx do
    gluetun(ctx.bypass, "running", 0)
    start_vpn(ctx, {:error, :leak_detected})

    assert_receive {:engine_stop, :leak_detected}, 1_000
    refute_received {:engine_start, _}
    assert %Status{vpn: {:down, :leak_detected}} = Status.get(ctx.status)
  end

  test "a stopped VPN stops the engine and shows the last log line", ctx do
    File.write!(Path.join(ctx.dir, "gluetun.log"), "INFO ok\nERROR [vpn] auth failed\n")
    gluetun(ctx.bypass, "stopped", 0)
    start_vpn(ctx, :ok)

    assert_receive {:engine_stop, {:vpn_down, "ERROR [vpn] auth failed"}}, 1_000
  end

  test "a preflight problem is reported without calling gluetun", ctx do
    File.write!(Path.join(ctx.dir, "preflight"), "net_admin=missing\ntun=ok\n")
    start_vpn(ctx, :ok)

    assert_receive {:engine_stop, :missing_net_admin}, 1_000
    assert %Status{vpn: {:down, :missing_net_admin}} = Status.get(ctx.status)
  end

  test "an unreachable gluetun is reported", ctx do
    Bypass.down(ctx.bypass)
    start_vpn(ctx, :ok)
    assert_receive {:engine_stop, :vpn_unreachable}, 1_000
  end
end
```

The test drives the engine through an `:engine_fun` option. The production default calls `Engine.start_engine/2` and `Engine.stop_engine/2` on `opts[:engine]`.

- [ ] **Step 2: Run test to verify it fails**

Run: `./dev mix test test/mydia/downloads/built_in/vpn_test.exs`
Expected: FAIL, module undefined.

- [ ] **Step 3: Write the implementation**

```elixir
defmodule Mydia.Downloads.BuiltIn.Vpn do
  @moduledoc """
  Gates the built-in engine on the VPN.

  Gluetun is started by the container entrypoint as root, so this process only
  observes it: the entrypoint's preflight file, then gluetun's control server.
  The engine starts only while gluetun reports `running` and the leak check
  passed for the current tunnel; anything else stops it with a named reason.
  """

  use GenServer
  require Logger

  alias Mydia.Downloads.BuiltIn.{Engine, GluetunClient, LeakCheck, Status}

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def child_spec(opts),
    do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  @impl true
  def init(opts) do
    engine = Keyword.get(opts, :engine, Engine)

    state = %{
      config: Keyword.fetch!(opts, :config),
      status: Keyword.get(opts, :status, Status),
      base_url: Keyword.get(opts, :base_url, "http://127.0.0.1:8000"),
      interval_ms: Keyword.get(opts, :interval_ms, 10_000),
      engine_fun: Keyword.get(opts, :engine_fun, default_engine_fun(engine)),
      leak_check:
        Keyword.get(opts, :leak_check, fn ->
          LeakCheck.run(relay_url: Mydia.Metadata.metadata_relay_url())
        end),
      verified?: false
    }

    Status.put(state.status, :vpn, :connecting)
    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = poll(state)
    Process.send_after(self(), :poll, state.interval_ms)
    {:noreply, state}
  end

  defp poll(state) do
    with :ok <- preflight(state.config.gluetun_dir),
         {:ok, req} <- client(state),
         {:ok, "running"} <- status(req, state) do
      up(req, state)
    else
      {:down, reason} -> down(state, reason)
    end
  end

  defp up(req, %{verified?: false} = state) do
    case state.leak_check.() do
      :ok -> up(req, %{state | verified?: true})
      {:error, reason} -> down(state, reason)
    end
  end

  defp up(req, state) do
    public_ip =
      case GluetunClient.public_ip(req) do
        {:ok, ip} -> ip
        _ -> nil
      end

    Status.put(
      state.status,
      :vpn,
      {:up, %{provider: state.config.vpn_provider, public_ip: public_ip}}
    )

    port =
      case GluetunClient.forwarded_port(req) do
        {:ok, n} when n > 0 ->
          Status.put(state.status, :port, {:forwarded, n, DateTime.utc_now()})
          n

        _ ->
          Status.put(state.status, :port, {:static, state.config.port})
          state.config.port
      end

    state.engine_fun.({:start, port})
    state
  end

  defp down(state, reason) do
    Status.put(state.status, :vpn, {:down, reason})
    state.engine_fun.({:stop, reason})
    %{state | verified?: false}
  end

  defp preflight(dir) do
    case File.read(Path.join(dir, "preflight")) do
      {:ok, body} ->
        cond do
          body =~ "net_admin=missing" -> {:down, :missing_net_admin}
          body =~ "tun=missing" -> {:down, :missing_tun}
          true -> :ok
        end

      {:error, _} ->
        {:down, :vpn_unreachable}
    end
  end

  defp client(state) do
    case File.read(Path.join(state.config.gluetun_dir, "apikey")) do
      {:ok, key} -> {:ok, GluetunClient.new(state.base_url, String.trim(key))}
      {:error, _} -> {:down, :vpn_unreachable}
    end
  end

  defp status(req, state) do
    case GluetunClient.vpn_status(req) do
      {:ok, "running"} = ok -> ok
      {:ok, _other} -> {:down, vpn_down_reason(state.config.gluetun_dir)}
      {:error, _} -> {:down, :vpn_unreachable}
    end
  end

  defp vpn_down_reason(dir) do
    with {:ok, log} <- File.read(Path.join(dir, "gluetun.log")),
         line when is_binary(line) <-
           log |> String.split("\n", trim: true) |> Enum.reverse() |> Enum.find(&(&1 =~ "ERROR")) do
      {:vpn_down, line}
    else
      _ -> :vpn_down
    end
  end

  defp default_engine_fun(engine) do
    fn
      {:start, port} -> Engine.start_engine(engine, port)
      {:stop, reason} -> Engine.stop_engine(engine, reason)
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./dev mix test test/mydia/downloads/built_in/vpn_test.exs`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/mydia/downloads/built_in/vpn.ex test/mydia/downloads/built_in/vpn_test.exs
git commit -m "feat(downloads): gate the built-in engine on the VPN"
```

---

### Task 8: Supervisor and application wiring

**Files:**
- Create: `lib/mydia/downloads/built_in/supervisor.ex`
- Modify: `lib/mydia/application.ex` (children list near `client_health_children/0`)
- Test: `test/mydia/downloads/built_in/supervisor_test.exs`

**Interfaces:**
- Consumes: everything above.
- Produces:
  - `BuiltIn.Supervisor.children(config :: Config.t, opts) :: [child_spec]`, pure. Opts: `:rqbit_path`, `:api_port`, `:credentials`.
  - `BuiltIn.Supervisor.start_link(opts)`: loads `Config` from `System.get_env/0` and the other configured clients' types, calls `BuiltIn.put_runtime/1` when enabled, and starts `children/2`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Mydia.Downloads.BuiltIn.SupervisorTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.BuiltIn.{Config, Engine, Status, Vpn}
  alias Mydia.Downloads.BuiltIn.Supervisor, as: BuiltInSupervisor

  defp ids(children), do: Enum.map(children, &Supervisor.child_spec(&1, []).id)

  test "disabled starts nothing" do
    assert BuiltInSupervisor.children(%Config{enabled?: false}, credentials: {"u", "p"}) == []
  end

  test "without a VPN the engine autostarts" do
    children = BuiltInSupervisor.children(%Config{enabled?: true}, credentials: {"u", "p"})
    assert ids(children) == [Status, Engine]
    {Engine, opts} = Enum.at(children, 1)
    assert opts[:autostart] == true
  end

  test "with a VPN the gate starts it" do
    children =
      BuiltInSupervisor.children(%Config{enabled?: true, vpn?: true}, credentials: {"u", "p"})

    assert ids(children) == [Status, Engine, Vpn]
    {Engine, opts} = Enum.at(children, 1)
    assert opts[:autostart] == false
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./dev mix test test/mydia/downloads/built_in/supervisor_test.exs`
Expected: FAIL, module undefined.

- [ ] **Step 3: Write the implementation**

```elixir
defmodule Mydia.Downloads.BuiltIn.Supervisor do
  @moduledoc """
  Starts the built-in torrent client when `Config` says it is enabled.

  `rest_for_one`: if `Status` restarts, the engine and the VPN gate restart
  with it, so nothing reports into a fresh, empty status.
  """

  use Supervisor

  alias Mydia.Downloads.BuiltIn
  alias Mydia.Downloads.BuiltIn.{Config, Engine, Status, Vpn}

  @torrent_types [:qbittorrent, :transmission, :rqbit, :rtorrent]

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    config = Config.load(System.get_env(), other_client_types())
    credentials = {"mydia", Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)}
    api_port = Keyword.get(opts, :api_port, 3030)

    if config.enabled? do
      BuiltIn.put_runtime(%{api_port: api_port, credentials: credentials, config: config})
    end

    children(config, Keyword.merge(opts, credentials: credentials, api_port: api_port))
    |> Supervisor.init(strategy: :rest_for_one)
  end

  @spec children(Config.t(), keyword()) :: [Supervisor.child_spec() | {module(), keyword()}]
  def children(%Config{enabled?: false}, _opts), do: []

  def children(%Config{} = config, opts) do
    engine =
      {Engine,
       config: config,
       credentials: Keyword.fetch!(opts, :credentials),
       api_port: Keyword.get(opts, :api_port, 3030),
       rqbit_path: Keyword.get(opts, :rqbit_path, "rqbit"),
       autostart: not config.vpn?}

    base = [{Status, warnings: config.warnings}, engine]
    if config.vpn?, do: base ++ [{Vpn, config: config}], else: base
  end

  # Types of the clients configured other than the built-in one: database rows
  # plus DOWNLOAD_CLIENT_<N>_* blocks. The built-in client is rejected
  # explicitly: after a supervisor restart it is already in the runtime list,
  # and counting it as an rqbit client would switch it off.
  defp other_client_types do
    Mydia.Settings.list_download_client_configs()
    |> Enum.filter(& &1.enabled)
    |> Enum.reject(&BuiltIn.managed?(%{connection_settings: &1.connection_settings}))
    |> Enum.map(& &1.type)
    |> Enum.filter(&(&1 in @torrent_types))
  rescue
    _ -> []
  end
end
```

- [ ] **Step 4: Wire it into the application**

In `lib/mydia/application.ex`, next to `client_health_children/0`, add and splice into the children list the same way the health monitors are spliced:

```elixir
  # The built-in torrent client reads the configured download clients, so it
  # is gated like ClientHealth: the supervisor's own process has no SQL
  # Sandbox connection under mix test.
  defp built_in_torrent_children do
    if Application.get_env(:mydia, :start_health_monitors, true) do
      [Mydia.Downloads.BuiltIn.Supervisor]
    else
      []
    end
  end
```

Place it after the `Ecto.Migrator` child and the config merge, so `list_download_client_configs/0` reads a migrated database.

- [ ] **Step 5: Run tests**

Run: `./dev mix test test/mydia/downloads/built_in/`
Expected: PASS.

- [ ] **Step 6: Run the app and check it by hand**

Run: `./dev up -d` with `rqbit` on PATH (added to devenv in Task 11; until then `nix shell nixpkgs#rqbit`) and no torrent client configured. Then:
- `./dev logs phoenix` shows no rqbit errors
- `curl -u mydia:<password from iex BuiltIn.runtime()> http://127.0.0.1:3030/torrents` returns `{"torrents":[]}`
- Admin, Download Clients lists "Built-in" as healthy

- [ ] **Step 7: Commit**

```bash
git add lib/mydia/downloads/built_in/supervisor.ex lib/mydia/application.ex test/mydia/downloads/built_in/supervisor_test.exs
git commit -m "feat(downloads): start the built-in torrent client"
```

---

### Task 9: Admin status panel

**Files:**
- Create: `lib/mydia_web/live/admin_download_clients_live/built_in_components.ex`
- Modify: `lib/mydia_web/live/admin_download_clients_live/index.ex` (mount, a `handle_info`, a `handle_event`), `index.html.heex` (render above the client list)
- Test: `test/mydia_web/live/admin_download_clients_live/built_in_test.exs`

**Interfaces:**
- Consumes: `Status`, `Status.describe/1`, `Engine.restart/1`, `BuiltIn.runtime/0`.
- Produces: element ids `#built-in-torrent`, `#built-in-engine-state`, `#built-in-vpn-state`, `#built-in-port-state`, `#built-in-vpn-experimental`, `#built-in-restart`, `#built-in-warnings`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule MydiaWeb.AdminDownloadClientsLive.BuiltInTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mydia.Downloads.BuiltIn
  alias Mydia.Downloads.BuiltIn.{Config, Status}

  setup %{conn: conn} do
    unique_id = System.unique_integer([:positive])

    {:ok, user} =
      Mydia.Accounts.create_user(%{
        email: "admin_#{unique_id}@example.com",
        username: "admin_#{unique_id}",
        password_hash: "$2b$12$test",
        role: "admin"
      })

    {:ok, token, _} = Mydia.Auth.Guardian.encode_and_sign(user)
    conn = Plug.Test.init_test_session(conn, %{guardian_default_token: token})

    start_supervised!({Status, name: Status})

    BuiltIn.put_runtime(%{
      api_port: 3030,
      credentials: {"mydia", "x"},
      config: %Config{enabled?: true, vpn?: true, vpn_provider: "protonvpn"}
    })

    on_exit(fn -> BuiltIn.clear_runtime() end)
    %{conn: conn}
  end

  test "shows engine, VPN and port state and updates live", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/clients")

    assert has_element?(view, "#built-in-torrent")
    assert has_element?(view, "#built-in-vpn-experimental")

    Status.put(:vpn, {:down, :missing_net_admin})
    assert render(element(view, "#built-in-vpn-state")) =~ "cap_add"

    Status.put(:vpn, {:up, %{provider: "protonvpn", public_ip: "203.0.113.9"}})
    Status.put(:port, {:forwarded, 40_123, DateTime.utc_now()})
    Status.put(:engine, :running)

    assert render(element(view, "#built-in-vpn-state")) =~ "203.0.113.9"
    assert render(element(view, "#built-in-port-state")) =~ "40123"
    assert render(element(view, "#built-in-engine-state")) =~ "Running"
  end

  test "no panel when the built-in client is not running", %{conn: conn} do
    BuiltIn.clear_runtime()
    {:ok, view, _html} = live(conn, ~p"/admin/clients")
    refute has_element?(view, "#built-in-torrent")
  end
end
```

Match the session setup to what `test/mydia_web/live/admin_download_clients_live_test.exs` does for its authenticated tests; copy its helper if it differs from `init_test_session` above.

- [ ] **Step 2: Run test to verify it fails**

Run: `./dev mix test test/mydia_web/live/admin_download_clients_live/built_in_test.exs`
Expected: FAIL, `#built-in-torrent` not found.

- [ ] **Step 3: Write the component**

```elixir
defmodule MydiaWeb.AdminDownloadClientsLive.BuiltInComponents do
  @moduledoc false
  use MydiaWeb, :html

  alias Mydia.Downloads.BuiltIn.Status

  attr :status, Status, required: true
  attr :vpn?, :boolean, required: true

  def built_in_panel(assigns) do
    ~H"""
    <div id="built-in-torrent" class="card bg-base-200 mb-4">
      <div class="card-body gap-3 p-4">
        <div class="flex items-center gap-2">
          <.icon name="hero-arrow-down-tray" class="size-5" />
          <h3 class="font-semibold">{gettext("Built-in torrent client")}</h3>
          <span :if={@vpn?} id="built-in-vpn-experimental" class="badge badge-sm badge-warning">
            {gettext("VPN experimental")}
          </span>
          <button
            id="built-in-restart"
            class="btn btn-ghost btn-xs ml-auto"
            phx-click="restart_built_in"
          >
            <.icon name="hero-arrow-path" class="size-4" /> {gettext("Restart")}
          </button>
        </div>
        <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
          <dt class="text-base-content/70">{gettext("Engine")}</dt>
          <dd id="built-in-engine-state">{engine_label(@status.engine)}</dd>
          <%= if @vpn? do %>
            <dt class="text-base-content/70">{gettext("VPN")}</dt>
            <dd id="built-in-vpn-state">{vpn_label(@status.vpn)}</dd>
          <% end %>
          <dt class="text-base-content/70">{gettext("Port")}</dt>
          <dd id="built-in-port-state">{port_label(@status.port)}</dd>
        </dl>
        <ul :if={@status.warnings != []} id="built-in-warnings" class="text-sm text-warning">
          <li :for={warning <- @status.warnings}>{Status.describe(warning)}</li>
        </ul>
      </div>
    </div>
    """
  end

  defp engine_label(:running), do: gettext("Running")
  defp engine_label(:starting), do: gettext("Starting")
  defp engine_label(:disabled), do: gettext("Disabled")
  defp engine_label({:stopped, reason}), do: gettext("Stopped: %{why}", why: Status.describe(reason))

  defp engine_label({:crashed, reason, restarts}),
    do:
      gettext("Crashed after %{n} restarts: %{why}", n: restarts, why: Status.describe(reason))

  defp vpn_label(:off), do: gettext("Off")
  defp vpn_label(:connecting), do: gettext("Connecting")

  defp vpn_label({:up, %{provider: provider, public_ip: ip}}),
    do: gettext("Connected via %{provider}, public IP %{ip}", provider: provider, ip: ip || "?")

  defp vpn_label({:down, reason}), do: Status.describe(reason)

  defp port_label(nil), do: gettext("Not set yet")
  defp port_label({:static, n}), do: gettext("%{port} (fixed)", port: n)

  defp port_label({:forwarded, n, since}),
    do: gettext("%{port} (forwarded since %{since})", port: n, since: Calendar.strftime(since, "%H:%M"))

  defp port_label({:failed, reason, last}),
    do: gettext("%{port}: %{why}", port: last, why: Status.describe(reason))
end
```

- [ ] **Step 4: Wire the LiveView**

In `index.ex` `mount/3`, before `load_data()`:

```elixir
    built_in = Mydia.Downloads.BuiltIn.runtime()

    if connected?(socket) and built_in do
      Phoenix.PubSub.subscribe(Mydia.PubSub, Mydia.Downloads.BuiltIn.Status.topic())
    end

    socket =
      socket
      |> assign(:built_in_vpn?, built_in != nil and built_in.config.vpn?)
      |> assign(:built_in_status, built_in && safe_status())
```

Add:

```elixir
  @impl true
  def handle_info({:built_in_status, status}, socket),
    do: {:noreply, assign(socket, :built_in_status, status)}

  @impl true
  def handle_event("restart_built_in", _params, socket) do
    Mydia.Downloads.BuiltIn.Engine.restart()
    {:noreply, put_flash(socket, :info, gettext("Restarting the built-in torrent client"))}
  end

  defp safe_status do
    Mydia.Downloads.BuiltIn.Status.get()
  catch
    :exit, _ -> %Mydia.Downloads.BuiltIn.Status{}
  end
```

If the LiveView already defines `handle_info/2` clauses, add this clause beside them instead of a second `@impl` block. In `index.html.heex`, directly before `download_clients_tab`:

```heex
    <MydiaWeb.AdminDownloadClientsLive.BuiltInComponents.built_in_panel
      :if={@built_in_status}
      status={@built_in_status}
      vpn?={@built_in_vpn?}
    />
```

- [ ] **Step 5: Run tests**

Run: `./dev mix test test/mydia_web/live/admin_download_clients_live/ test/mydia_web/live/admin_download_clients_live_test.exs`
Expected: PASS.

- [ ] **Step 6: Extract gettext strings**

Run: `./dev mix gettext.extract --merge` and check the catalog per `lib/mydia_web/gettext/README.md`.

- [ ] **Step 7: Commit**

```bash
git add lib/mydia_web/live/admin_download_clients_live/ test/mydia_web/live/admin_download_clients_live/ priv/gettext
git commit -m "feat(admin): built-in torrent client status panel"
```

---

### Task 10: Gluetun split-tunnel patch

**Files:**
- Create: `vendor/gluetun/VERSION` (contents: `v3.41.3`)
- Create: `vendor/gluetun/patches/0001-split-tunnel.patch`
- Create: `vendor/gluetun/README.md`
- Inside the gluetun checkout (the patch's content): `internal/splittunnel/rules.go`, `internal/splittunnel/rules_test.go`, edits to `internal/configuration/settings/` (new env var), `internal/wireguard/run.go`, `internal/provider/utils/openvpn.go`, `internal/firewall/enable.go`, and the DNS settings default.

**Interfaces:**
- Produces: gluetun honours `SPLIT_TUNNEL_GID=<gid>`. Unset means unchanged upstream behaviour.

This task is done in a scratch checkout and exported as a patch.

- [ ] **Step 1: Check out the pinned release**

```bash
mkdir -p "$SCRATCH/gluetun" && cd "$SCRATCH/gluetun"
git clone --depth 1 --branch v3.41.3 https://github.com/qdm12/gluetun.git src
cd src && git checkout -b mydia-split-tunnel
```

(`$SCRATCH` is the session scratchpad. The module path is `github.com/qdm12/gluetun`; the repo now redirects from the `passteque` org.)

- [ ] **Step 2: Write the failing Go test for the rule builder**

`internal/splittunnel/rules_test.go`:

```go
package splittunnel

import (
	"net/netip"
	"testing"
)

func TestIptablesInstructions(t *testing.T) {
	s := Settings{GID: 1500, Mark: 0x5154, Interface: "tun0",
		Endpoint: netip.MustParseAddr("192.0.2.10"), DNSPort: 53}

	got := s.IptablesInstructions(false)
	want := []string{
		"-t mangle -A OUTPUT -d 192.0.2.10 -j RETURN",
		"-t mangle -A OUTPUT -m owner --gid-owner 1500 -j MARK --set-mark 0x5154",
		"-t mangle -A OUTPUT -m owner --uid-owner 0 -j MARK --set-mark 0x5154",
		"-A OUTPUT -m mark --mark 0x5154 -o lo -j ACCEPT",
		"-A OUTPUT -m mark --mark 0x5154 -o tun0 -j ACCEPT",
		"-A OUTPUT -m mark --mark 0x5154 -j DROP",
		"-A INPUT -i tun0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT",
		"-A INPUT -i tun0 -j DROP",
		"-t nat -A OUTPUT -m mark --mark 0x5154 -p udp --dport 53 -j DNAT --to-destination 127.0.0.1:53",
		"-t nat -A OUTPUT -m mark --mark 0x5154 -p tcp --dport 53 -j DNAT --to-destination 127.0.0.1:53",
	}
	if len(got) != len(want) {
		t.Fatalf("got %d instructions, want %d:\n%v", len(got), len(want), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("instruction %d:\n got %q\nwant %q", i, got[i], want[i])
		}
	}
}

func TestRemoveInstructionsUseDelete(t *testing.T) {
	s := Settings{GID: 1500, Mark: 0x5154, Interface: "tun0",
		Endpoint: netip.MustParseAddr("192.0.2.10"), DNSPort: 53}
	for _, instruction := range s.IptablesInstructions(true) {
		if !containsFlag(instruction, "-D") {
			t.Errorf("remove instruction lacks -D: %q", instruction)
		}
	}
}

func TestForwardedPortInstruction(t *testing.T) {
	s := Settings{Interface: "tun0"}
	if got := s.InboundPortInstruction(40123, false); got != "-I INPUT -i tun0 -p tcp --dport 40123 -j ACCEPT" {
		t.Errorf("got %q", got)
	}
}
```

Run: `go test ./internal/splittunnel/`
Expected: FAIL, package has no non-test files.

- [ ] **Step 3: Write the rule builder**

`internal/splittunnel/rules.go`:

```go
// Package splittunnel builds the routing and firewall rules for
// SPLIT_TUNNEL_GID mode: only sockets owned by the given group, and gluetun's
// own root processes, use the VPN. Everything else in the container keeps the
// main routing table and is not filtered.
package splittunnel

import (
	"fmt"
	"net/netip"
	"strings"
)

type Settings struct {
	GID       uint32
	Mark      uint32
	Interface string
	Endpoint  netip.Addr
	DNSPort   uint16
}

func (s Settings) IptablesInstructions(remove bool) []string {
	op := "-A"
	if remove {
		op = "-D"
	}
	mark := fmt.Sprintf("0x%x", s.Mark)
	dns := fmt.Sprintf("127.0.0.1:%d", s.DNSPort)
	return []string{
		fmt.Sprintf("-t mangle %s OUTPUT -d %s -j RETURN", op, s.Endpoint),
		fmt.Sprintf("-t mangle %s OUTPUT -m owner --gid-owner %d -j MARK --set-mark %s", op, s.GID, mark),
		fmt.Sprintf("-t mangle %s OUTPUT -m owner --uid-owner 0 -j MARK --set-mark %s", op, mark),
		fmt.Sprintf("%s OUTPUT -m mark --mark %s -o lo -j ACCEPT", op, mark),
		fmt.Sprintf("%s OUTPUT -m mark --mark %s -o %s -j ACCEPT", op, mark, s.Interface),
		fmt.Sprintf("%s OUTPUT -m mark --mark %s -j DROP", op, mark),
		fmt.Sprintf("%s INPUT -i %s -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT", op, s.Interface),
		fmt.Sprintf("%s INPUT -i %s -j DROP", op, s.Interface),
		fmt.Sprintf("-t nat %s OUTPUT -m mark --mark %s -p udp --dport 53 -j DNAT --to-destination %s", op, mark, dns),
		fmt.Sprintf("-t nat %s OUTPUT -m mark --mark %s -p tcp --dport 53 -j DNAT --to-destination %s", op, mark, dns),
	}
}

// InboundPortInstruction inserts ahead of the INPUT DROP so the forwarded
// port, and only it, is reachable from the VPN side.
func (s Settings) InboundPortInstruction(port uint16, remove bool) string {
	op := "-I"
	if remove {
		op = "-D"
	}
	return fmt.Sprintf("%s INPUT -i %s -p tcp --dport %d -j ACCEPT", op, s.Interface, port)
}

func containsFlag(instruction, flag string) bool {
	for _, field := range strings.Fields(instruction) {
		if field == flag {
			return true
		}
	}
	return false
}
```

Run: `go test ./internal/splittunnel/`
Expected: PASS.

- [ ] **Step 4: Wire split mode into gluetun**

Make these edits in the gluetun checkout, reading each file first (signatures may differ by a few names from what is listed here; the behaviour is what matters):

1. **Setting.** In `internal/configuration/settings/`, add `SplitTunnelGID *uint32` to the firewall settings struct, read from env `SPLIT_TUNNEL_GID` alongside the other firewall variables, defaulting to nil. Validation: when set, `FIREWALL_OUTBOUND_SUBNETS` and `FIREWALL_INPUT_PORTS` are ignored with a warning.
2. **Firewall** (`internal/firewall/enable.go`, `enable`). When split mode is on, skip `SetIPv4AllPolicies(ctx, "DROP")`, `SetIPv6AllPolicies` and the local-network/outbound-subnet rules. Instead run `splittunnel.Settings{...}.IptablesInstructions(false)` through `runIptablesInstructions` (`internal/firewall/iptables/iptables.go:43`), using the VPN endpoint from `allowVPNIP` and the interface from settings. On disable, run `IptablesInstructions(true)`. In `internal/firewall/ports.go` `SetAllowedPort`, emit `InboundPortInstruction` for the VPN interface instead of the default accept rule.
3. **WireGuard routing** (`internal/wireguard/run.go:132-142`). In split mode, replace the inverted `AddRule(priority, firewallMark, ...)` with a rule for `fwmark <split mark>` (no `FlagInvert`) to table `firewallMark`. Add an `unreachable` default route in that table at metric `4294967295`, so marked traffic fails closed when the WireGuard route disappears. The WireGuard socket keeps its own `FirewallMark`, so its encrypted packets still use the main table.
4. **OpenVPN routing** (`internal/provider/utils/openvpn.go`, near the existing `pull-filter` lines at 173). In split mode add `lines.add("pull-filter", "ignore", `"redirect-gateway"`)` and `lines.add("route-noexec")`. After the tunnel is up, add the default route via the tun interface to the split table, the same table and rule as step 3. Look for the OpenVPN "tunnel up" hook in `internal/vpn/` and call the same helper from there.
5. **DNS.** In split mode, the DNS server binds `127.0.0.1:53` only and gluetun does not write `/etc/resolv.conf`. Find the write in `internal/dns/loop.go` (the file that mentions `resolv.conf`) and skip it.
6. **Mark constant.** Use `0x5154` for the split mark everywhere, defined once in `internal/splittunnel`.

Run: `go build ./... && go test ./internal/splittunnel/ ./internal/firewall/... ./internal/wireguard/...`
Expected: build OK, tests PASS.

- [ ] **Step 5: Export the patch**

```bash
git add -A && git commit -m "Add SPLIT_TUNNEL_GID split-tunnel mode"
git format-patch -1 --stdout > <worktree>/vendor/gluetun/patches/0001-split-tunnel.patch
echo v3.41.3 > <worktree>/vendor/gluetun/VERSION
```

- [ ] **Step 6: Write `vendor/gluetun/README.md`**

```markdown
# Patched gluetun

Mydia's experimental VPN runs gluetun with one patch series that adds a split
mode, `SPLIT_TUNNEL_GID=<gid>`. Only sockets owned by that group (the
built-in rqbit and `torrent-curl`) and by uid 0 (gluetun and its OpenVPN
child) are routed through the VPN and kill-switched. The rest of the container
keeps its normal route.

- `VERSION`: the upstream tag the patches apply to.
- `patches/0001-split-tunnel.patch`: the split mode. `internal/splittunnel`
  builds the iptables rules and has the unit test.

## Rebasing onto a new release

1. Clone the new tag, `git am vendor/gluetun/patches/*.patch`.
2. Fix conflicts. They land in `internal/firewall/enable.go`,
   `internal/wireguard/run.go`, `internal/provider/utils/openvpn.go` and the
   DNS loop, where upstream changes most.
3. `go test ./internal/splittunnel/ ./internal/firewall/... ./internal/wireguard/...`
4. Re-export with `git format-patch`, bump `VERSION`, run the smoke test below.

## Smoke test

Build the image (`docker build -t mydia:builtin-vpn .`) and run it with
`--cap-add NET_ADMIN --device /dev/net/tun` and a ProtonVPN WireGuard login
(`MYDIA_VPN_SERVICE_PROVIDER=protonvpn`, `MYDIA_VPN_VPN_TYPE=wireguard`,
`MYDIA_VPN_WIREGUARD_PRIVATE_KEY`, `MYDIA_VPN_VPN_PORT_FORWARDING=on`). Then:

1. `docker exec <c> su-exec mydia torrent-curl -s https://relay.mydia.dev/ip`
   prints the VPN address; the same with plain `curl` prints the host's.
2. Admin, Download Clients shows the VPN connected, its public IP, a forwarded
   port, and the engine running.
3. `docker exec <c> ip link del tun0`: `torrent-curl --max-time 5` fails,
   plain `curl` still works, and within 10 seconds the admin page shows the
   VPN down and the engine stopped.
4. Without `--cap-add NET_ADMIN` the admin page shows the `cap_add` message
   and the engine stays stopped.
5. A magnet grabbed from the UI downloads and imports.
```

- [ ] **Step 7: Commit**

```bash
git add vendor/gluetun
git commit -m "feat(vpn): gluetun split-tunnel patch"
```

---

### Task 11: Docker image, entrypoint, devenv and docs

**Files:**
- Modify: `Dockerfile` (new `rqbit` and `gluetun` stages; runtime packages; group and setgid binaries)
- Create: `docker/vpn-preflight.sh`
- Modify: `docker-entrypoint-prod.sh` (call the preflight before `exec su-exec`)
- Modify: `devenv.nix` (`packages`: add `rqbit`)
- Modify: `docs/using/reference/environment-variables.md`, `docs/using/reference/download-clients.md`, `lib/mydia/downloads/README.md`, `vendor/gluetun/README.md`

- [ ] **Step 1: Build stages**

In `Dockerfile`, after the `nifs` stage:

```dockerfile
# ── rqbit: the built-in torrent engine ───────────────────────────────────────
FROM toolchain AS rqbit
ARG RQBIT_VERSION=9.0.1
RUN --mount=type=cache,target=/root/.cargo/registry,sharing=locked \
    --mount=type=cache,target=/root/.cargo/git,sharing=locked \
    cargo install rqbit --version "${RQBIT_VERSION}" --locked --root /out

# ── gluetun: patched for split tunnelling (vendor/gluetun/README.md) ─────────
FROM golang:1.26-alpine AS gluetun
RUN apk add --no-cache git
COPY vendor/gluetun /vendor-gluetun
RUN set -eu; \
    git clone --depth 1 --branch "$(cat /vendor-gluetun/VERSION)" \
      https://github.com/qdm12/gluetun.git /src; \
    cd /src; \
    git -c user.email=build@mydia -c user.name=build am /vendor-gluetun/patches/*.patch; \
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/gluetun ./cmd/gluetun
```

Check `toolchain` has `cargo` on PATH (it builds the NIFs, so it does). If the `rqbit` crate needs `openssl-dev` on musl, add it to that stage with `apk add --no-cache openssl-dev`.

- [ ] **Step 2: Runtime stage**

Add `openvpn iptables ip6tables iproute2` to the existing `apk add` list (`curl` is already there). After the `adduser` line:

```dockerfile
COPY --from=rqbit /out/bin/rqbit /usr/local/bin/rqbit
COPY --from=gluetun /out/gluetun /usr/local/bin/gluetun
# The built-in engine and the leak check's curl run as group mydia-torrent:
# gluetun's split mode tunnels exactly that group. setgid on the binaries is
# what switches the group, so the BEAM needs no capabilities.
RUN addgroup -S mydia-torrent && \
    cp /usr/bin/curl /usr/local/bin/torrent-curl && \
    chgrp mydia-torrent /usr/local/bin/rqbit /usr/local/bin/torrent-curl && \
    chmod 2755 /usr/local/bin/rqbit /usr/local/bin/torrent-curl
COPY docker/vpn-preflight.sh /usr/local/bin/vpn-preflight
RUN chmod 755 /usr/local/bin/vpn-preflight
```

- [ ] **Step 3: Write `docker/vpn-preflight.sh`**

```sh
#!/bin/sh
# Starts the experimental VPN (patched gluetun) when MYDIA_VPN_SERVICE_PROVIDER
# is set. Runs as root from the entrypoint. Never fails the boot: problems go
# into /config/gluetun/preflight, which Mydia shows in the admin UI.
set -u

[ -n "${MYDIA_VPN_SERVICE_PROVIDER:-}" ] || exit 0

dir=/config/gluetun
mkdir -p "$dir"
chown mydia:mydia "$dir"

# CAP_NET_ADMIN is bit 12 of the effective capability mask.
net_admin=missing
capeff=$(awk '/^CapEff/ {print $2}' /proc/self/status)
[ $(( (0x$capeff >> 12) & 1 )) -eq 1 ] && net_admin=ok
tun=ok
[ -c /dev/net/tun ] || tun=missing
printf 'net_admin=%s\ntun=%s\n' "$net_admin" "$tun" > "$dir/preflight"
chmod 644 "$dir/preflight"

if [ "$net_admin" = missing ] || [ "$tun" = missing ]; then
    echo "VPN: preflight failed (net_admin=$net_admin tun=$tun); torrents stay stopped"
    exit 0
fi

key=$(head -c 24 /dev/urandom | base64 | tr -d '/+=')
printf '%s' "$key" > "$dir/apikey"
chown mydia:mydia "$dir/apikey"
chmod 400 "$dir/apikey"

gid=$(getent group mydia-torrent | cut -d: -f3)

# MYDIA_VPN_FOO=bar becomes FOO=bar for gluetun. Mydia's own values are
# exported last so they win over any user attempt to set them.
gluetun_env=$(env | sed -n 's/^MYDIA_VPN_//p')

(
    while true; do
        env -i PATH="$PATH" $gluetun_env \
            SPLIT_TUNNEL_GID="$gid" \
            HTTP_CONTROL_SERVER_ADDRESS=127.0.0.1:8000 \
            HTTP_CONTROL_SERVER_AUTH_DEFAULT_ROLE="{\"auth\":\"apikey\",\"apikey\":\"$key\"}" \
            DNS_ADDRESS=127.0.0.1 \
            /usr/local/bin/gluetun >> "$dir/gluetun.log" 2>&1
        echo "gluetun exited with $?; restarting in 5s" >> "$dir/gluetun.log"
        sleep 5
    done
) &

echo "VPN: gluetun started for provider $MYDIA_VPN_SERVICE_PROVIDER (experimental)"
```

`$gluetun_env` word-splits on whitespace, so a value containing spaces breaks. That is acceptable for the PoC; note it in the docs. A value with spaces needs a follow-up that writes an env file.

- [ ] **Step 4: Call it from the entrypoint**

In `docker-entrypoint-prod.sh`, immediately before the `echo "Starting Mydia..."` banner:

```sh
/usr/local/bin/vpn-preflight
```

- [ ] **Step 5: devenv**

Add `rqbit` to the `packages = with pkgs; [` list in `devenv.nix`, so the built-in engine runs in the native dev loop. The VPN is Docker-only.

- [ ] **Step 6: Build and smoke test**

```bash
docker build -t mydia:builtin-vpn .
docker run --rm -d --name mydia-vpn --cap-add NET_ADMIN --device /dev/net/tun \
  -e MYDIA_VPN_SERVICE_PROVIDER=protonvpn \
  -e MYDIA_VPN_VPN_TYPE=wireguard \
  -e MYDIA_VPN_WIREGUARD_PRIVATE_KEY=<key from the Proton config> \
  -e MYDIA_VPN_VPN_PORT_FORWARDING=on \
  -e MYDIA_VPN_SERVER_COUNTRIES=Netherlands \
  -p 4000:4000 mydia:builtin-vpn
```

Run the five checks in `vendor/gluetun/README.md`, "Smoke test" (written in Task 10), with `<c>` = `mydia-vpn`. Record any deviation in that README.

- [ ] **Step 7: Docs**

- `docs/using/reference/environment-variables.md`: a "Built-in torrent client" table with the five variables from Global Constraints, and a note that `MYDIA_VPN_*` takes any gluetun variable with the prefix, links to gluetun's provider docs, and lists the two container requirements (`cap_add: [NET_ADMIN]`, `devices: [/dev/net/tun]`).
- `docs/using/reference/download-clients.md`: a "Built-in" section explaining auto-enable, the download path, and that the VPN is experimental. Include a compose example with ProtonVPN WireGuard and one with PIA OpenVPN (`MYDIA_VPN_OPENVPN_USER`, `MYDIA_VPN_OPENVPN_PASSWORD`).
- `lib/mydia/downloads/README.md`: a short "Built-in client" section covering the managed guard in `Rqbit`, the runtime injection in `RuntimeConfig`, and that the engine's state lives in `BuiltIn.Status`.

- [ ] **Step 8: Commit**

```bash
git add Dockerfile docker/vpn-preflight.sh docker-entrypoint-prod.sh devenv.nix docs lib/mydia/downloads/README.md
git commit -m "feat(docker): ship rqbit and the patched gluetun"
```

---

### Task 12: Precommit and risk check

- [ ] **Step 1:** Run `./dev mix precommit` in chunks if it exceeds the 600s Bash limit (see `test/README.md`). Fix anything it reports in files this plan touched.
- [ ] **Step 2:** Run `git diff --name-only origin/master...` and confirm every file is in this plan's File Structure. An unexpected file is a stale-read signal; investigate before continuing.
- [ ] **Step 3:** If Repowise is reachable, run `get_risk` with `changed_files` from Step 2 and address any `missing_cochanges`, or note why they don't apply.
- [ ] **Step 4:** Commit any fixes.
