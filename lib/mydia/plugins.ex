defmodule Mydia.Plugins do
  @moduledoc """
  Context for the WASM plugin platform.

  This is the public surface for the plugin platform: listing/resolving plugins,
  fanning events to them (U5), and the install/approve/revoke/remove lifecycle
  (U8) layered over the DB-overlay config (U4), the SSRF-gated host functions
  (U6), and the index (U7).

  ## Capability approval (KTD6, deny-by-default)

  Grants live **server-side** in `Mydia.Settings.PluginConfig`, never in the
  manifest. `install/2` activates a plugin only with the capabilities the admin
  approved; `revoke/1` clears them and deactivates. The runtime `Registry` holds
  only *active* (approved + enabled) descriptors — the set the dispatcher fans
  events to — while the DB holds every installed plugin for the admin UI.

  ## Trust boundary: bundled vs. third-party manifests

  Image-bundled system plugins (`priv/plugins/*.json`) are part of the trusted
  host release. `ensure_bundled/0` grants their complete shipped capability set
  and enables them on first discovery, then replaces the grant with the shipped
  manifest's exact effective set on every later release — a system plugin never
  waits for admin approval and never runs on a stale grant.

  Third-party manifests — a reinstalled index package, any row whose
  `source_url` is not `"bundled"` — never widen a grant on revision: re-storing
  what the plugin *declares* leaves the grant exactly as approved, so nothing is
  ever silently widened. The cost is that such a plugin can end up asking for
  more than it holds and failing `Denied` at the one call site that needed the
  new capability. `needs_reapproval?/1` and `ungranted_capabilities/1` detect
  that state (see `Mydia.Plugins.Capabilities` for the comparison), `activate/1`
  warns about it when the plugin starts, the admin UI badges it, and `approve/2`
  is the way out: it grants the currently requested set.
  """

  require Logger

  alias Mydia.Plugins.Capabilities
  alias Mydia.Plugins.DeclaredSettings
  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Grants
  alias Mydia.Plugins.Host
  alias Mydia.Plugins.HostFunctions
  alias Mydia.Plugins.Index
  alias Mydia.Plugins.Instance
  alias Mydia.Plugins.Instances
  alias Mydia.Plugins.Manifest
  alias Mydia.Plugins.Plugin
  alias Mydia.Plugins.Registry
  alias Mydia.Plugins.Shelves
  alias Mydia.Plugins.Sources
  alias Mydia.Settings

  @doc "Lists all registered plugin descriptors."
  @spec list_plugins() :: [Plugin.t()]
  def list_plugins, do: Registry.list()

  @doc "Fetches a plugin descriptor by slug."
  @spec get_plugin(String.t()) :: {:ok, Plugin.t()} | {:error, Error.t()}
  def get_plugin(slug), do: Registry.lookup(slug)

  @doc "True when a plugin is registered under `slug`."
  @spec plugin_registered?(String.t()) :: boolean()
  def plugin_registered?(slug), do: Registry.registered?(slug)

  ## Event dispatch (U5)

  @doc """
  Returns the enabled plugins subscribed to `event_type`.

  A plugin subscribes by listing the event in its manifest `events:subscribe`
  capability; only enabled plugins are returned (deny-by-default).
  """
  @spec subscribers(String.t()) :: [Plugin.t()]
  def subscribers(event_type) when is_binary(event_type) do
    Registry.list()
    |> Enum.filter(fn %Plugin{} = p -> p.enabled and event_type in p.events end)
  end

  @doc """
  Lists enabled plugins that declare a `connection` descriptor (U8), with the
  data the host-run device flow needs: the descriptor, the effective `client_id`
  (operator setting override, else the manifest default), and the plugin's
  granted `net:http` hosts (the egress allowlist the connect flow runs under).
  """
  @spec list_connectable() :: [map()]
  def list_connectable do
    for config <- Mydia.Settings.list_plugin_configs(),
        config.enabled,
        is_map(config.manifest),
        descriptor = config.manifest["connection"],
        is_map(descriptor),
        Manifest.device_flow?(%Manifest{connection: descriptor}) do
      %{
        slug: config.slug,
        name: config.name,
        descriptor: descriptor,
        client_id: Map.get(config.settings || %{}, "client_id") || descriptor["client_id"],
        allowed_hosts: connectable_hosts(config.slug)
      }
    end
  end

  @doc """
  Enabled plugins holding `surfaces:page`, as navbar entries. The title and icon
  come from the manifest's `page` descriptor, validated at parse time.
  """
  @spec list_pages() :: [%{slug: String.t(), title: String.t(), icon: String.t()}]
  def list_pages do
    pages =
      for %Plugin{enabled: true, page: %{"title" => title, "icon" => icon}} = plugin <-
            list_plugins(),
          Plugin.granted?(plugin, "surfaces:page") do
        %{slug: plugin.slug, title: title, icon: icon}
      end

    Enum.sort_by(pages, & &1.title)
  end

  defp connectable_hosts(slug) do
    case get_plugin(slug) do
      {:ok, %Plugin{} = plugin} -> Plugin.granted_http_hosts(plugin)
      _ -> []
    end
  end

  @doc """
  Invokes a plugin for an event on every enabled instance.

  This is the dispatcher's default invoker. Each instance gets its own call (or
  durable job) with that instance's settings injected under `config`. Instances
  run one after another inside the dispatcher's per-plugin task; one instance
  failing does not skip the others. Returns `{:ok, results}` with one entry per
  instance, or the first `{:error, _}` so the dispatcher logs it.
  """
  @spec invoke_plugin(Plugin.t(), map()) :: {:ok, [term()]} | {:error, term()}
  def invoke_plugin(%Plugin{} = plugin, event) do
    results =
      for %Instance{} = instance <- Instances.list_enabled(plugin.slug) do
        invoke_plugin(plugin, instance, event)
      end

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, results}
      error -> error
    end
  end

  @doc """
  Invokes a plugin for an event on one instance, routing by delivery mode.

  `:inline` plugins run synchronously through `Mydia.Plugins.Host`. `:durable`
  plugins (the bundled notifier) enqueue a durable Oban delivery job carrying
  the instance id.
  """
  @spec invoke_plugin(Plugin.t(), Instance.t(), map()) :: {:ok, term()} | {:error, term()}
  def invoke_plugin(%Plugin{delivery: :durable} = plugin, %Instance{} = instance, event) do
    Mydia.Plugins.Notifier.Delivery.enqueue(plugin.slug, instance.id, build_payload(event))
  end

  def invoke_plugin(%Plugin{} = plugin, %Instance{} = instance, event) do
    payload = event |> build_payload() |> Map.put("config", Instances.config_for(instance))
    Host.call(plugin.slug, plugin.entrypoint, payload, instance_id: instance.id)
  end

  @doc """
  Invokes a plugin instance's `on-schedule` handler for a scheduled tick.

  Single-flight `:skip`: if a sibling invocation of the same instance is already
  running, the tick is a no-op (`{:error, %Error{type: :busy}}`), so ticks never
  pile up. The instance settings are injected under `config`, exactly as the
  event paths do.
  """
  @spec invoke_plugin_schedule(String.t(), binary(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def invoke_plugin_schedule(slug, instance_id, opts \\ []) when is_binary(slug) do
    with {:ok, instance} <- fetch_instance(slug, instance_id) do
      now = Keyword.get(opts, :now, System.system_time(:second))
      payload = %{"slug" => slug, "now" => now, "config" => Instances.config_for(instance)}

      Host.call(slug, "on-schedule", payload,
        handler: :on_schedule,
        single_flight: :skip,
        instance_id: instance.id
      )
    end
  end

  @doc """
  Calls a plugin instance's 1.5 `setup` export with the operator's answers.

  `request` carries `step`, `input_json` and `state_json` (the setup protocol in
  the plugin host reference). Runs under `plugins.setup_timeout_ms` and waits
  for the instance lock. Errors: `:unsupported` when the manifest does not
  declare `setup: true` (or the guest predates 1.5), `:not_found` for an
  unknown instance or a plugin that is not running, `:guest_error` carrying the
  guest's own message when it returns `Err`.
  """
  @spec invoke_setup(String.t(), binary(), map()) :: {:ok, map()} | {:error, Error.t()}
  def invoke_setup(slug, instance_id, %{step: step} = request) when is_binary(slug) do
    with {:ok, _plugin} <- setup_capable(slug),
         {:ok, instance} <- fetch_instance(slug, instance_id) do
      payload = %{
        "step" => step,
        "input_json" => Map.get(request, :input_json, "{}"),
        "state_json" => Map.get(request, :state_json, "{}"),
        "config" => Instances.config_for(instance)
      }

      Host.call(slug, "setup", payload, handler: :setup, instance_id: instance.id)
    end
  end

  @doc """
  Calls a plugin instance's 1.5 `check-health` export under the event timeout.
  Same errors as `invoke_setup/3`.
  """
  @spec invoke_check_health(String.t(), binary()) :: {:ok, map()} | {:error, Error.t()}
  def invoke_check_health(slug, instance_id) when is_binary(slug) do
    with {:ok, _plugin} <- setup_capable(slug),
         {:ok, instance} <- fetch_instance(slug, instance_id) do
      Host.call(slug, "check-health", %{}, handler: :check_health, instance_id: instance.id)
    end
  end

  @doc """
  Calls a plugin's 1.6 `fill-shelf` export for one of its declared shelves, as
  `user`. The plugin's settings ride along under `config`, as they do for a
  page call.

  Options: `:exclude` (maps with `:media_type`, `:tmdb_id`, `:tvdb_id`,
  `:imdb_id`), `:limit`, `:now` (a `DateTime`, or Unix seconds).

  Errors: `:unsupported` for a guest older than 1.6, `:busy` when a fill for
  this user is already running, `:guest_error` carrying the guest's message.
  """
  @spec invoke_fill_shelf(String.t(), String.t(), Mydia.Accounts.User.t(), keyword()) ::
          {:ok, %{items: [map()]}} | {:error, Error.t()}
  def invoke_fill_shelf(slug, shelf_key, %Mydia.Accounts.User{} = user, opts \\ [])
      when is_binary(slug) and is_binary(shelf_key) do
    # The instance-scoped imports (KV, link-request) need one; a multi_instance
    # plugin has no default instance, so it fills with none.
    instance = Instances.default_instance(slug)

    payload = %{
      "shelf" => shelf_key,
      "exclude" => Keyword.get(opts, :exclude, []),
      "limit" => Keyword.get(opts, :limit, 12),
      "now" => unix_seconds(Keyword.get(opts, :now)),
      "config" => if(instance, do: Instances.config_for(instance), else: plugin_settings(slug))
    }

    Host.call(slug, "fill-shelf", payload,
      handler: :fill_shelf,
      acting_user_id: user.id,
      role: user.role,
      instance_id: instance && instance.id
    )
  end

  defp unix_seconds(%DateTime{} = now), do: DateTime.to_unix(now)
  defp unix_seconds(now) when is_integer(now), do: now
  defp unix_seconds(_), do: System.system_time(:second)

  defp plugin_settings(slug) do
    case Settings.get_plugin_config_by_slug(slug) do
      %{settings: %{} = settings} -> settings
      _ -> %{}
    end
  end

  # setup and check-health are the plugin-driven admin surfaces; a manifest
  # opts in with `setup: true`.
  defp setup_capable(slug) do
    case get_plugin(slug) do
      {:ok, %Plugin{setup: true} = plugin} ->
        {:ok, plugin}

      {:ok, %Plugin{}} ->
        {:error, Error.new(:unsupported, "plugin #{slug} does not declare setup in its manifest")}

      _ ->
        {:error, Error.new(:not_found, "plugin #{slug} is not running")}
    end
  end

  defp fetch_instance(slug, instance_id) do
    with {:ok, id} <- Ecto.UUID.cast(instance_id || ""),
         %Instance{plugin_slug: ^slug} = instance <- Instances.get(id) do
      {:ok, instance}
    else
      _ ->
        {:error, Error.new(:not_found, "instance #{inspect(instance_id)} not found for #{slug}")}
    end
  end

  @doc """
  Ensures a single-instance plugin has its default instance. Multi-instance
  plugins get instances only through setup, so this is a no-op for them.
  """
  @spec ensure_default_instance(Plugin.t()) :: :ok
  def ensure_default_instance(%Plugin{multi_instance: true}), do: :ok

  def ensure_default_instance(%Plugin{} = plugin) do
    # Also heals installs that saved plugin settings before those reached the
    # default instance: the plugin config's settings win over the instance's.
    config = Settings.get_plugin_config_by_slug(plugin.slug)
    Instances.default_instance(plugin.slug)
    Instances.merge_default_settings(plugin.slug, (config && config.settings) || %{})
    :ok
  end

  @doc """
  Builds the JSON-encodable payload handed to a guest for an event.

  Atoms (`actor_type`) are stringified so the boundary stays language-agnostic.
  """
  @spec build_payload(map()) :: map()
  def build_payload(event) do
    %{
      "event" => Map.get(event, :type),
      "category" => Map.get(event, :category),
      "severity" => to_string_or_nil(Map.get(event, :severity)),
      "actor_type" => to_string_or_nil(Map.get(event, :actor_type)),
      "actor_id" => Map.get(event, :actor_id),
      "resource_type" => Map.get(event, :resource_type),
      "resource_id" => Map.get(event, :resource_id),
      "metadata" => Map.get(event, :metadata) || %{}
    }
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)

  @doc """
  Fires a synthetic `event_type` at a single plugin for the admin Test button
  (U7, R10/R11).

  Calls `Host.call/4` directly (bypassing `invoke_plugin/2`'s delivery routing,
  so durable plugins like the bundled notifier run synchronously and surface
  immediately rather than via an Oban job) with `test_run: true`, so the markers
  and guest logs for the run are badged as a test. Runs in a supervised Task so
  the caller (LiveView) does not block. Returns `:ok` when the plugin is running,
  `{:error, :not_running}` otherwise, and `{:error, :no_instance}` for a
  multi-instance plugin with no enabled instance.
  """
  @spec test_invoke(String.t(), String.t()) :: :ok | {:error, :not_running | :no_instance}
  def test_invoke(slug, event_type) when is_binary(slug) and is_binary(event_type) do
    with {:ok, %Plugin{} = plugin} <- running_plugin(slug),
         %Instance{} = instance <- test_instance(plugin) do
      payload =
        event_type
        |> synthetic_event()
        |> build_payload()
        |> Map.put("config", Instances.config_for(instance))

      Task.Supervisor.start_child(Mydia.TaskSupervisor, fn ->
        Host.call(plugin.slug, plugin.entrypoint, payload,
          test_run: true,
          instance_id: instance.id
        )
      end)

      :ok
    else
      nil -> {:error, :no_instance}
      {:error, _} = err -> err
    end
  end

  defp running_plugin(slug) do
    case get_plugin(slug) do
      {:ok, %Plugin{} = plugin} -> {:ok, plugin}
      _ -> {:error, :not_running}
    end
  end

  # The Test button exercises a single-instance plugin's default instance and a
  # multi-instance plugin's first enabled instance (per-instance checks are the
  # instance card's Test button, which calls check-health).
  defp test_instance(%Plugin{multi_instance: true} = plugin),
    do: List.first(Instances.list_enabled(plugin.slug))

  defp test_instance(%Plugin{} = plugin), do: Instances.default_instance(plugin.slug)

  defp synthetic_event(event_type) do
    %{
      type: event_type,
      category: "media",
      severity: :info,
      actor_type: :system,
      actor_id: "plugin_test",
      resource_type: "media_item",
      resource_id: Ecto.UUID.generate(),
      metadata: %{
        "title" => "Test Movie",
        "media_type" => "movie",
        "year" => 2026,
        "test" => true
      }
    }
  end

  @doc """
  Rehydrates installed plugins into the runtime registry post-boot.

  Called from `Mydia.Application` after the supervision tree starts, mirroring
  `Mydia.Downloads.register_clients/0`. Loads every enabled `PluginConfig` that
  carries a verified artifact and activates it (registers the descriptor and
  starts its pool). Failures are logged and skipped so one bad plugin can't stop
  boot.
  """
  @spec register_plugins() :: :ok
  def register_plugins do
    # Reconcile bundled system plugins (approved + enabled) so they show in the
    # admin UI. Gated by the same flag the app uses for boot-time side effects, so
    # the test suite's app boot doesn't write to the shared DB (tests call
    # ensure_bundled/0 explicitly when they need it).
    maybe_ensure_bundled()

    # Persist YAML/env-declared plugin instances and settings before plugins start
    # scheduling against them. Same boot-side-effect gate as bundled seeding.
    if Application.get_env(:mydia, :start_health_monitors, true) do
      Mydia.Plugins.DeclaredSources.sync()
      Mydia.Plugins.RuntimeInstances.sync()
      DeclaredSettings.sync_all()
    end

    Settings.get_db_plugin_configs()
    |> Enum.filter(& &1.enabled)
    |> Enum.each(fn config ->
      case activate(config) do
        {:ok, _} ->
          :ok

        {:error, error} ->
          # A declared-settings sync may have pre-registered the descriptor.
          deactivate(config.slug)
          Logger.warning("could not activate plugin #{config.slug}: #{inspect(error)}")
      end
    end)
  end

  @doc """
  Seeds bundled plugins (`ensure_bundled/0`) unless boot-time side effects are
  disabled — the test suite sets `start_health_monitors: false` so neither its app
  boot nor a connected admin-page mount writes the shared DB (and the empty-state
  test stays deterministic).

  Safe to call on every admin Plugins page view: it is idempotent (seeds only a
  missing slug, reconciles only a changed manifest or grant) and is the
  reconciliation point a long-lived node otherwise lacks. `ensure_bundled/0` runs
  only once at boot, so without this an instance that started before a bundled
  manifest shipped never discovers the new plugin until it restarts.

  Discovery alone is not enough: `ensure_bundled/0` is seeding-only, and this
  pass's `enabled: true` row reads as live in the admin UI while `Host`/`Registry`
  hold nothing for the slug (every event dropped). So this also starts every
  enabled bundled plugin the pass created or that is not yet running, through the
  same isolated-failure activation `register_plugins/0` uses.
  """
  @spec maybe_ensure_bundled() :: :ok
  def maybe_ensure_bundled do
    if Application.get_env(:mydia, :start_health_monitors, true) do
      ensure_bundled()
      start_enabled_bundled_plugins()
    else
      :ok
    end
  end

  # Starts the pools for enabled bundled rows that are not already running — the
  # activation half of mount-time reconciliation (`maybe_ensure_bundled/0`).
  # `register_plugins/0` performs this at boot; a node that discovers a bundled
  # manifest later has no other path to it. Rows the operator disabled are left
  # stopped, and an already-running slug is skipped so a re-render never restarts
  # a live pool. Failures are logged and skipped, matching `register_plugins/0`.
  defp start_enabled_bundled_plugins do
    Settings.get_db_plugin_configs()
    |> Enum.filter(&(&1.enabled and &1.source_url == "bundled"))
    |> Enum.reject(&Host.running?(&1.slug))
    |> Enum.each(fn config ->
      case activate(config) do
        {:ok, _} ->
          :ok

        {:error, error} ->
          deactivate(config.slug)
          Logger.warning("could not activate plugin #{config.slug}: #{inspect(error)}")
      end
    end)

    :ok
  end

  @doc """
  Discovers every bundled plugin shipped in `priv/plugins/` and seeds it approved
  and enabled, without copying any wasm bytes into the DB.

  A bundled plugin is part of the trusted host release, so first discovery stores
  its manifest, settings, and exact effective capability grant in one insert and
  enables it — there is no approval step. Each `priv/plugins/*.json` manifest is
  parsed; its bytes resolve from the filesystem at activation (see
  `resolve_artifact/2`), so the seeded row carries `wasm_module: nil`.

  ## Reconcile (built-in upgrade)

  A pre-existing `source_url == "bundled"` row is reconciled against the shipped
  manifest: its metadata and `granted_capabilities` are replaced, in one update,
  with the current manifest's exact effective set (including the `net:http` hosts
  an operator setting derives — see `effective_grants/2`). A capability the
  shipped manifest no longer declares therefore drops out of the grant instead of
  lingering. The administrator's `enabled` choice and settings are preserved, so
  reconciliation never re-enables a plugin the operator disabled.

  An install that ran the older copy-into-DB seeding has its bundled row carrying
  stale bytes in `wasm_module`, which the resolver's DB layer would prefer over a
  newer image artifact. Reconciliation nulls `wasm_module`/`integrity_hash` on any
  `source_url == "bundled"` row so resolution falls through to the filesystem and
  a newer image ships newer code automatically.

  Non-bundled rows — an index plugin, or a same-slug third-party install — are
  left entirely alone: they keep explicit approval and re-approval.
  """
  @spec ensure_bundled() :: :ok
  def ensure_bundled do
    Enum.each(bundled_manifests(), &seed_or_reconcile/1)
  end

  defp bundled_manifests do
    Application.app_dir(:mydia, "priv/plugins")
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      with {:ok, json} <- File.read(path),
           {:ok, raw} <- Jason.decode(json),
           {:ok, manifest} <- Manifest.parse(raw) do
        [{manifest, raw}]
      else
        other ->
          Logger.warning("could not load bundled manifest #{path}: #{inspect(other)}")
          []
      end
    end)
  end

  defp seed_or_reconcile({manifest, raw}) do
    case Settings.get_plugin_config_by_slug(manifest.slug) do
      nil -> seed_bundled(manifest, raw)
      %Settings.PluginConfig{} = config -> reconcile_bundled(config, manifest, raw)
    end
  end

  # First discovery of a bundled slug: one insert carrying the manifest, the
  # settings derived from it, and the grant that matches them exactly — approved
  # and enabled, with no admin step. Bytes stay out of the DB (`wasm_module: nil`);
  # they resolve from the filesystem at activation.
  defp seed_bundled(manifest, raw) do
    settings = bundled_settings(raw)
    manifest_map = manifest_to_map(manifest)

    attrs = %{
      slug: manifest.slug,
      name: manifest.name,
      version: manifest.version,
      source_url: "bundled",
      integrity_hash: nil,
      manifest: manifest_map,
      wasm_module: nil,
      granted_capabilities: effective_grants(manifest_map, settings),
      enabled: true,
      settings: settings
    }

    case Settings.create_plugin_config(attrs) do
      {:ok, config} -> DeclaredSettings.sync(config.slug)
      {:error, reason} -> log_bundled_reconciliation_error(manifest.slug, reason)
    end
  end

  # A bundled plugin declares its delivery mode in its manifest (durable enqueues
  # an Oban job; inline runs synchronously). Default inline when unspecified.
  defp bundled_settings(raw) do
    case Map.get(raw, "delivery") do
      mode when mode in ["durable", "inline"] -> %{"delivery" => mode}
      _ -> %{"delivery" => "inline"}
    end
  end

  # Reconcile a pre-existing bundled row against the current bundled manifest
  # (built-in upgrade): replace the stored manifest/metadata and grant in one
  # update, then null any stale DB bytes. Non-bundled rows (e.g. an index plugin)
  # are left entirely alone — they keep explicit approval and re-approval.
  defp reconcile_bundled(%Settings.PluginConfig{source_url: "bundled"} = config, manifest, raw) do
    case refresh_bundled_state(config, manifest, raw) do
      {:ok, updated} -> reconcile_bundled_artifact(updated)
      {:error, _reason} -> :ok
    end
  end

  defp reconcile_bundled(_config, _manifest, _raw), do: :ok

  # Replace the manifest metadata *and* the grant together, so a revised manifest
  # never leaves the row holding a stale one. The grant is the manifest's exact
  # effective set — the persisted settings still decide the derived `net:http`
  # hosts — which both widens to the shipped set and drops capabilities the
  # manifest no longer declares. `enabled` is deliberately absent from attrs: the
  # administrator's choice survives every host upgrade.
  defp refresh_bundled_state(config, manifest, raw) do
    manifest_map = manifest_to_map(manifest)
    # The delivery mode lives in settings; a shipped change must reach existing rows.
    settings = Map.merge(config.settings || %{}, bundled_settings(raw))

    attrs =
      %{}
      |> put_changed(:manifest, manifest_map, config.manifest)
      |> put_changed(:settings, settings, config.settings)
      |> put_changed(:name, manifest.name, config.name)
      |> put_changed(:version, manifest.version, config.version)
      |> put_changed(
        :granted_capabilities,
        effective_grants(manifest_map, settings),
        config.granted_capabilities
      )

    if attrs == %{} do
      {:ok, config}
    else
      case Settings.update_plugin_config(config, attrs) do
        {:ok, updated} ->
          {:ok, updated}

        {:error, reason} ->
          log_bundled_reconciliation_error(config.slug, reason)
          {:error, reason}
      end
    end
  end

  # A write failure must not abort the surrounding `Enum.each/2` over every
  # bundled manifest: log it and continue to the next plugin.
  defp log_bundled_reconciliation_error(slug, reason) do
    Logger.error("plugin #{slug}: could not reconcile bundled configuration: #{inspect(reason)}")
    :ok
  end

  defp put_changed(attrs, _key, value, value), do: attrs
  defp put_changed(attrs, key, value, _current), do: Map.put(attrs, key, value)

  # Guard against bricking: only null the DB bytes when a filesystem replacement
  # actually resolves (override or bundled artifact present). In an environment
  # where the .wasm was not built (a toolchain-less dev compile that skipped),
  # nulling would strip an enabled plugin's only artifact, so we keep the DB
  # bytes and log instead.
  defp reconcile_bundled_artifact(%Settings.PluginConfig{wasm_module: wasm} = config)
       when is_binary(wasm) do
    case resolve_artifact(%{config | wasm_module: nil}) do
      {:ok, _bytes} ->
        Settings.update_plugin_config(config, %{wasm_module: nil, integrity_hash: nil})
        :ok

      {:error, _} ->
        Logger.warning(
          "plugin #{config.slug}: keeping DB bytes — no filesystem artifact to fall back to"
        )

        :ok
    end
  end

  defp reconcile_bundled_artifact(_config), do: :ok

  ## Install lifecycle (U8)

  @doc """
  Installs a plugin from a catalog `entry`, activating it with the approved
  capabilities.

  Fetches and integrity-verifies the package (U7), persists the verified
  artifact + manifest + **approved** grants server-side (U4), and — if any
  capability was granted — registers the descriptor and starts its pool.

  Approval is all-or-nothing in v1: `opts[:grants]` defaults to the manifest's
  full declared capability set. Passing `grants: %{}` installs the plugin
  **inactive** (deny-by-default) — nothing runs until `approve/2`. Extra `opts`
  (`:allow_private`, `:resolver`) are forwarded to the gate for tests.

  Installing over an existing sideloaded or index install replaces its bytes,
  manifest and grant and restarts it on the new build, which is how the store
  replaces a sideload or applies an update. A bundled slug is refused.
  """
  @spec install(Index.Entry.t(), keyword()) :: {:ok, Plugin.t() | :inactive} | {:error, Error.t()}
  def install(%Index.Entry{} = entry, opts \\ []) do
    grants = Keyword.get(opts, :grants, entry.manifest.capabilities)

    with :ok <- refuse_bundled(entry.slug),
         {:ok, %{wasm: wasm, hash: hash}} <- Index.fetch_package(entry, opts),
         {:ok, config} <- persist_install(entry, wasm, hash, grants),
         # Only after the new build is stored, so a failed write leaves the
         # running plugin untouched.
         :ok <- deactivate(entry.slug) do
      config |> with_declared_settings() |> finish_activation()
    end
  end

  @doc """
  Installs a plugin from a local `.wasm` component and its `manifest.json`,
  bypassing the index. This is how an operator tests a plugin that has not been
  published yet (`mydia-cli plugin install`).

  The files come from the operator's own disk, so they are trusted the way the
  override directory is: there is no catalog to verify an integrity hash
  against, and the recorded hash is simply the file's. Capability approval is
  not bypassed. The plugin installs inactive and waits for approval in
  Admin > Plugins, unless `approve: true` grants the declared set right away
  through `approve/2`.

  Reinstalling over an existing sideloaded or index install replaces its bytes
  and manifest and clears its grant, as a fresh install would. A bundled slug is
  refused: its bytes come from the image, and replacing them is what
  `PLUGINS_OVERRIDE_DIR` is for.
  """
  @spec install_file(Path.t(), Path.t(), keyword()) ::
          {:ok, Plugin.t() | :inactive} | {:error, Error.t()}
  def install_file(wasm_path, manifest_path, opts \\ []) do
    with {:ok, wasm} <- read_local(wasm_path, "package"),
         {:ok, json} <- read_local(manifest_path, "manifest"),
         {:ok, manifest} <- Manifest.parse(json),
         :ok <- refuse_bundled(manifest.slug),
         entry = local_entry(manifest, wasm_path, wasm),
         :ok <- deactivate(manifest.slug),
         {:ok, config} <- persist_install(entry, wasm, entry.integrity, %{}) do
      config = with_declared_settings(config)

      if Keyword.get(opts, :approve, false),
        do: approve(config.slug),
        else: finish_activation(config)
    end
  end

  defp read_local(path, what) do
    case File.read(path) do
      {:ok, bytes} ->
        {:ok, bytes}

      {:error, reason} ->
        {:error,
         Error.new(:invalid_config, "cannot read #{what} #{path}: #{:file.format_error(reason)}")}
    end
  end

  defp refuse_bundled(slug) do
    case Settings.get_plugin_config_by_slug(slug) do
      %{source_url: "bundled"} ->
        {:error,
         Error.new(
           :invalid_config,
           "#{slug} is a bundled plugin; replace its bytes with PLUGINS_OVERRIDE_DIR instead"
         )}

      _ ->
        :ok
    end
  end

  defp local_entry(manifest, wasm_path, wasm) do
    %Index.Entry{
      slug: manifest.slug,
      name: manifest.name,
      version: manifest.version,
      description: manifest.description,
      author: manifest.author,
      package_url: "file://" <> Path.expand(wasm_path),
      integrity: :crypto.hash(:sha256, wasm) |> Base.encode16(case: :lower),
      manifest: manifest
    }
  end

  @doc """
  Approves the full declared capability set for an already-installed plugin and
  activates it.

  Used by the install-then-approve flow (AE1), by re-approval after a
  third-party capability change — their grants never auto-expand, so a revised
  manifest that newly requests more requires a fresh approval here — and by
  bundled reconciliation, which shares `effective_grants/2` so the approved set
  and the reconciled set can never disagree.
  """
  @spec approve(String.t(), keyword()) :: {:ok, Plugin.t()} | {:error, Error.t()}
  def approve(slug, _opts \\ []) do
    with {:ok, config} <- fetch_config(slug),
         manifest when not is_nil(manifest) <- config.manifest,
         {:ok, config} <-
           Settings.update_plugin_config(config, %{
             granted_capabilities: effective_grants(manifest, config.settings),
             enabled: true
           }) do
      activate_and_reload(config)
    else
      nil -> {:error, Error.new(:invalid_config, "plugin #{slug} has no stored manifest")}
      {:error, _} = err -> err
    end
  end

  @doc """
  Returns the capabilities a plugin's stored manifest requests that its grant
  does not cover, as `%{class => [uncovered values]}` (`%{}` when the grant still
  covers everything).

  This is the manifest-revision drift described in the module doc: the comparison
  itself lives in `Mydia.Plugins.Capabilities`, which handles both a wholly new
  class and a widened payload (a new event, a new `net:http` host). A config with
  no stored manifest — an env-sourced row, whose declared set *is* its grant —
  reports nothing.
  """
  @spec ungranted_capabilities(Settings.PluginConfig.t() | String.t()) :: Capabilities.set()
  def ungranted_capabilities(%Settings.PluginConfig{} = config) do
    Capabilities.ungranted(declared_capabilities(config), config.granted_capabilities || %{})
  end

  def ungranted_capabilities(slug) when is_binary(slug) do
    case Settings.get_plugin_config_by_slug(slug) do
      nil -> %{}
      config -> ungranted_capabilities(config)
    end
  end

  @doc """
  True when an already-approved plugin's manifest now requests more than it was
  granted, so the operator must re-approve it for the new capabilities to work.

  A plugin holding no grant at all is *pending* approval, not awaiting a
  re-approval, so it is never reported here.
  """
  @spec needs_reapproval?(Settings.PluginConfig.t() | String.t()) :: boolean()
  def needs_reapproval?(%Settings.PluginConfig{} = config) do
    (config.granted_capabilities || %{}) != %{} and ungranted_capabilities(config) != %{}
  end

  def needs_reapproval?(slug) when is_binary(slug) do
    case Settings.get_plugin_config_by_slug(slug) do
      nil -> false
      config -> needs_reapproval?(config)
    end
  end

  defp declared_capabilities(%{manifest: %{"capabilities" => caps}}) when is_map(caps), do: caps
  defp declared_capabilities(_config), do: %{}

  @doc """
  Updates a plugin's operator-editable settings and recomputes its effective
  `net:http` host grant from the new values (host-granting settings — KTD1/KTD2).

  The effective allowlist is a **full replacement**
  (`already-granted static hosts ∪ host(host-granting setting values)`), so
  changing a configured URL drops the previously granted host — no stale-host
  accumulation. Recomputation only touches `net:http` when it was already granted
  (approved); an unapproved plugin keeps its empty grant and derives hosts at
  approve time, preserving deny-by-default. When the plugin is enabled the live
  registry descriptor is re-registered so the gate enforces the new hosts on the
  next call, without restarting the running pool.

  The static side is taken from the **grant**, not from the current manifest: a
  manifest revised to declare new hosts must not have them granted as a side
  effect of saving unrelated settings (that would widen a grant the operator
  never approved, and would clear the needs-re-approval state without them ever
  seeing the new host).
  """
  @spec update_settings(String.t(), map()) ::
          {:ok, Settings.PluginConfig.t()} | {:error, Error.t()}
  def update_settings(slug, settings) when is_map(settings) do
    with {:ok, config} <- fetch_config(slug),
         merged = Map.merge(config.settings || %{}, settings),
         granted = recompute_http_grant(config, merged),
         {:ok, updated} <-
           Settings.update_plugin_config(config, %{
             settings: merged,
             granted_capabilities: granted
           }) do
      # Guests read the default instance's settings (`Instances.config_for/1`),
      # not the plugin config, so a single-instance plugin needs them there too.
      Instances.merge_default_settings(slug, settings)
      if updated.enabled, do: reregister_descriptor(updated)
      {:ok, updated}
    end
  end

  @doc """
  Checks the `url` fields of `schema` that `settings` sets: blank or an
  absolute http(s) URL passes. Returns `{:error, message}` naming the first
  field that fails. Shared by the admin settings modal and
  `Mydia.Plugins.DeclaredSettings`.

  A scheme-less value (e.g. "ntfy.example.com/x") would derive no host,
  silently dropping the grant and breaking delivery, hence the check.
  """
  @spec validate_url_settings([map()], map()) :: :ok | {:error, String.t()}
  def validate_url_settings(schema, settings) do
    schema
    |> Enum.filter(&(&1["type"] == "url"))
    |> Enum.reduce_while(:ok, fn field, :ok ->
      value = Map.get(settings, field["key"])

      if blank_value?(value) or absolute_url?(value) do
        {:cont, :ok}
      else
        label = field["label"] || field["key"]
        {:halt, {:error, "#{label} must be a full URL including https://"}}
      end
    end)
  end

  defp blank_value?(value), do: is_nil(value) or value == ""

  defp absolute_url?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp absolute_url?(_), do: false

  @doc """
  Revokes all grants for `slug` and deactivates it.

  The plugin stays installed (its config and artifact remain) but inactive with
  no capabilities — re-approval is required to run it again (R8, R14).
  """
  @spec revoke(String.t()) :: {:ok, :revoked} | {:error, Error.t()}
  def revoke(slug) do
    with {:ok, config} <- fetch_config(slug),
         {:ok, _} <-
           Settings.update_plugin_config(config, %{granted_capabilities: %{}, enabled: false}) do
      deactivate(slug)
      reload()
      # A revoked plugin lost the grant its shelves were filled under. Purged
      # last: until the registry stops declaring the shelf, a Home visit would
      # create its row again.
      Shelves.purge(slug)
      {:ok, :revoked}
    end
  end

  @doc """
  Removes a plugin entirely: deactivates it and deletes its config (R14).

  A bundled plugin is refused: `ensure_bundled/0` would re-seed it approved and
  enabled on the next admin page load or boot. Disabling is its off switch.
  """
  @spec remove(String.t()) :: {:ok, :removed} | {:error, Error.t()}
  def remove(slug) do
    with {:ok, config} <- fetch_config(slug),
         :ok <- ensure_removable(config),
         {:ok, _} <- Settings.delete_plugin_config(config) do
      # Role ceilings went with the config row. Approvals and queued writes are
      # keyed by slug alone, so they are cleared too. The journal stays as
      # history and stays undoable: undo needs only the entry.
      Grants.purge(slug)
      deactivate(slug)
      reload()
      # Last, for the same reason as in revoke/1: no longer declared by now.
      Shelves.purge(slug)
      {:ok, :removed}
    end
  end

  defp ensure_removable(config) do
    if Sources.origin(config) == :bundled,
      do:
        {:error, Error.new(:unsupported, "Bundled plugins can't be removed; disable it instead.")},
      else: :ok
  end

  @doc "Enables or disables an installed plugin, starting/stopping its pool."
  @spec set_enabled(String.t(), boolean()) :: {:ok, Plugin.t() | :disabled} | {:error, Error.t()}
  def set_enabled(slug, true) do
    with {:ok, config} <- fetch_config(slug),
         {:ok, config} <- Settings.update_plugin_config(config, %{enabled: true}) do
      activate_and_reload(config)
    end
  end

  def set_enabled(slug, false) do
    with {:ok, config} <- fetch_config(slug),
         {:ok, _} <- Settings.update_plugin_config(config, %{enabled: false}) do
      deactivate(slug)
      reload()
      {:ok, :disabled}
    end
  end

  ## Update detection (U8, R14)

  @doc """
  Checks every configured source for newer versions of installed plugins and
  emits a `plugin.update_available` event per update found (surfaced in U9).

  Source fetch failures are logged and skipped. Returns the list of detected
  updates. Short-circuits (no fetch) when nothing is installed. `opts` are
  forwarded to the gate for tests.
  """
  @spec check_for_updates(keyword()) :: [map()]
  def check_for_updates(opts \\ []) do
    installed = Settings.get_db_plugin_configs()

    if installed == [] do
      []
    else
      entries = fetch_all_entries(opts)
      updates = detect_updates(installed, entries)
      Enum.each(updates, &emit_update_event/1)
      updates
    end
  end

  @doc """
  Pure comparison: returns `%{slug, current, latest}` for each installed config
  that a catalog `entry` offers in a newer version (R14, no false positives on
  equal versions). An installed plugin is only compared with entries from its
  own origin (`Mydia.Plugins.Sources.origin/1`), so a third-party catalog cannot
  announce an update for a plugin it did not install.
  """
  @spec detect_updates([Settings.PluginConfig.t()], [Index.Entry.t()]) :: [map()]
  def detect_updates(installed, entries) do
    Enum.flat_map(installed, fn config ->
      origin = Sources.origin(config)

      latest =
        entries
        |> Enum.filter(&(&1.slug == config.slug and Index.entry_origin(&1) == origin))
        |> latest_version()

      if latest && Index.version_newer?(latest, config.version) do
        [%{slug: config.slug, current: config.version, latest: latest}]
      else
        []
      end
    end)
  end

  defp fetch_all_entries(opts) do
    (Keyword.get(opts, :sources) || Index.sources())
    |> Enum.flat_map(fn source ->
      case Index.fetch_catalog(source, opts) do
        {:ok, entries} ->
          entries

        {:error, error} ->
          Logger.warning("update check could not fetch #{source.url}: #{inspect(error)}")
          []
      end
    end)
  end

  defp latest_version(entries) do
    entries
    |> Enum.map(& &1.version)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort(&(not Index.version_newer?(&2, &1)))
    |> List.first()
  end

  defp emit_update_event(%{slug: slug, current: current, latest: latest}) do
    Mydia.Events.create_event_async(%{
      category: "plugin",
      type: "plugin.update_available",
      actor_type: :system,
      actor_id: slug,
      metadata: %{"slug" => slug, "current_version" => current, "latest_version" => latest}
    })
  end

  # ── Internals ─────────────────────────────────────────────────────────────

  # Env-declared settings reach a fresh install before it activates, so its
  # first run has them and its net:http grant covers the declared URL.
  defp with_declared_settings(config) do
    DeclaredSettings.sync(config.slug)
    Settings.get_plugin_config_by_slug(config.slug) || config
  end

  defp persist_install(entry, wasm, hash, grants) do
    Settings.upsert_plugin_config(%{
      slug: entry.slug,
      name: entry.name,
      version: entry.version,
      source_url: entry.package_url,
      plugin_source_id: entry.source_id,
      integrity_hash: hash,
      manifest: manifest_to_map(entry.manifest),
      wasm_module: wasm,
      granted_capabilities: grants,
      enabled: grants != %{}
    })
  end

  # After install: activate when capabilities were granted, otherwise leave it
  # installed-but-inactive (deny-by-default).
  defp finish_activation(%{enabled: true} = config), do: activate_and_reload(config)

  defp finish_activation(%{enabled: false}) do
    reload()
    {:ok, :inactive}
  end

  defp activate_and_reload(config) do
    case activate(config) do
      {:ok, descriptor} ->
        reload()
        {:ok, descriptor}

      {:error, _} = err ->
        # A row that cannot activate must not claim to be enabled with no live
        # plugin behind it.
        _ = Settings.update_plugin_config(config, %{enabled: false})
        # A settings write may have pre-registered the descriptor; drop it.
        deactivate(config.slug)
        reload()
        err
    end
  end

  # Builds the runtime descriptor from the persisted config + manifest and starts
  # its pool with the gated host-function imports. The wasm bytes are resolved
  # through the layered resolver (override dir → DB blob → bundled priv/plugins).
  defp activate(config) do
    with manifest_map when not is_nil(manifest_map) <- config.manifest,
         {:ok, manifest} <- Manifest.parse(manifest_map),
         :ok <- check_host_version_floor(config, manifest),
         {:ok, wasm} <- resolve_artifact(config) do
      descriptor =
        Plugin.from_manifest(manifest,
          granted_capabilities: config.granted_capabilities || %{},
          enabled: true,
          source: :index,
          delivery: delivery_for(config)
        )

      warn_stale_grant(descriptor)

      case Host.start_plugin(config.slug, wasm, imports: HostFunctions.imports_for(config.slug)) do
        {:ok, _pid} ->
          result = Registry.register(config.slug, descriptor)
          ensure_default_instance(descriptor)
          result

        # wasmtime refuses a component built against a contract the host does not
        # provide at instantiation. Translate that link-time failure into an
        # actionable floor message rather than surfacing a raw NIF error (R7).
        {:error, %Error{type: type}} when type in [:compile_failed, :instantiate_failed] ->
          {:error,
           Error.new(
             :host_version,
             "plugin #{config.slug} requires a newer Mydia host (incompatible plugin contract)"
           )}

        {:error, _} = err ->
          err
      end
    else
      nil ->
        {:error, Error.new(:invalid_config, "plugin #{config.slug} has no manifest to activate")}

      {:error, _} = err ->
        err
    end
  end

  # Warns once per activation when a plugin is about to run on a grant narrower
  # than its manifest — the operator-actionable form of the `Denied` errors those
  # calls will otherwise produce with no other signal.
  #
  # Deliberately *not* logged per denied call: a denial can fire in a hot loop
  # (an event-driven handler retrying every event), and the condition is a
  # property of the install, not of any one call. Activation is where it becomes
  # live and is bounded — once per plugin per boot, plus once per enable/approve.
  defp warn_stale_grant(%Plugin{} = descriptor) do
    case Capabilities.ungranted(descriptor.capabilities, descriptor.granted_capabilities) do
      ungranted when ungranted == %{} ->
        :ok

      ungranted ->
        Logger.warning(
          "plugin #{descriptor.slug} requests capabilities it was not granted: " <>
            "#{Capabilities.summary(ungranted)}. Calls into those are denied until you " <>
            "re-approve the plugin under Configuration > Plugins."
        )
    end
  end

  # Refuses activation when the manifest's declared minimum host version exceeds
  # the running Mydia version, with an actionable message — before instantiation,
  # so the admin gets "requires mydia ≥ X" rather than a cryptic link-time trap
  # (R7). A manifest with no floor (the common case) always passes.
  #
  # Bundled plugins ship with the host that runs them, so a floor is meaningless
  # for them and is not enforced (simkl_sync declares its WIT contract version).
  defp check_host_version_floor(%{source_url: "bundled"}, _manifest), do: :ok

  defp check_host_version_floor(%{slug: slug}, %Manifest{min_host_version: floor}) do
    cond do
      is_nil(floor) ->
        :ok

      host_meets_floor?(floor) ->
        :ok

      true ->
        {:error,
         Error.new(
           :host_version,
           "plugin #{slug} requires mydia >= #{floor} (host is #{host_version()})"
         )}
    end
  end

  # A development build (`-dev` pre-release, built from source) meets any floor.
  # Otherwise the comparison ignores pre-release tags, so 0.16.0-beta.1 meets a
  # 0.16.0 floor: betas carry the feature the floor names.
  @doc false
  def host_meets_floor?(floor, host \\ host_version()) do
    case {Version.parse(host), Version.parse(floor)} do
      {{:ok, %Version{pre: ["dev" | _]}}, {:ok, _}} ->
        true

      {{:ok, host}, {:ok, min}} ->
        Version.compare(%{host | pre: []}, %{min | pre: []}) != :lt

      # If either side is unparseable, do not block activation on the floor.
      _ ->
        true
    end
  end

  # `:plugin_host_version` lets tests stand in for a release build.
  defp host_version do
    case Application.get_env(:mydia, :plugin_host_version) do
      vsn when is_binary(vsn) -> vsn
      _ -> app_version()
    end
  end

  defp app_version do
    case Application.spec(:mydia, :vsn) do
      vsn when is_list(vsn) -> List.to_string(vsn)
      _ -> "0.0.0"
    end
  end

  ## Layered artifact resolution (U3)

  @doc """
  Resolves a plugin's wasm bytes by layer, highest precedence first:

    1. **Override dir** — a `<slug>.wasm` (hyphenated or underscored) dropped in
       `PLUGINS_OVERRIDE_DIR`, for an operator patch/dev iteration.
    2. **DB blob** — `config.wasm_module`, the verified bytes of a network
       (index) plugin cached at install.
    3. **Bundled** — the image artifact at `priv/plugins/<underscored-slug>.wasm`,
       built from source by the `:plugins` mix compiler.

  Bundled/override bytes are trusted (the image, the operator's own volume), so
  integrity is not re-verified here — network integrity already happened at fetch
  time in `Mydia.Plugins.Index`. `opts[:override_dir]` and `opts[:bundled_dir]`
  exist for hermetic tests; production calls pass none.
  """
  @spec resolve_artifact(Settings.PluginConfig.t(), keyword()) ::
          {:ok, binary()} | {:error, Error.t()}
  def resolve_artifact(config, opts \\ []) do
    slug = config.slug
    override_dir = Keyword.get(opts, :override_dir, configured_override_dir())
    bundled_dir = Keyword.get(opts, :bundled_dir, bundled_plugins_dir())

    with :miss <- from_override(slug, override_dir),
         :miss <- from_db(config),
         :miss <- from_bundled(slug, bundled_dir) do
      {:error, Error.new(:invalid_config, "plugin #{slug} has no artifact to activate")}
    else
      {:ok, _bytes} = ok -> ok
    end
  end

  # Layer 1: operator override directory. Accepts both the hyphenated slug and
  # the underscored form (operators see the hyphenated slug in the UI; the
  # compiler emits the underscored filename), guarded against path traversal.
  defp from_override(_slug, dir) when dir in [nil, ""], do: :miss

  defp from_override(slug, dir) do
    names = Enum.uniq([slug, underscored(slug)])

    found =
      Enum.find_value(names, fn name ->
        path = Path.join(dir, name <> ".wasm")

        case read_within(dir, path) do
          {:ok, bytes} -> {bytes, path}
          :miss -> nil
        end
      end)

    case found do
      {bytes, path} ->
        Logger.info("plugin #{slug}: activating bytes from override dir #{path}")
        {:ok, bytes}

      nil ->
        Logger.debug(
          "plugin #{slug}: override dir #{dir} set but no matching .wasm; falling through"
        )

        :miss
    end
  end

  # Layer 2: DB-cached bytes (index plugins). Bundled rows carry nil here (U4).
  defp from_db(%{wasm_module: bytes}) when is_binary(bytes) and byte_size(bytes) > 0,
    do: {:ok, bytes}

  defp from_db(_), do: :miss

  # Layer 3: image-bundled artifact, built into priv/plugins by the compiler.
  defp from_bundled(slug, dir), do: read_within(dir, Path.join(dir, underscored(slug) <> ".wasm"))

  # Reads `path` only when it stays under `dir` (defence-in-depth traversal
  # guard — real slugs are regex-validated, but the guard is load-bearing
  # regardless of how the slug was sourced). File.read (not File.read!) so a file
  # vanishing between checks yields :miss rather than raising.
  defp read_within(dir, path) do
    with true <- within_dir?(dir, path),
         {:ok, bytes} <- File.read(path) do
      {:ok, bytes}
    else
      _ -> :miss
    end
  end

  defp within_dir?(dir, path) do
    String.starts_with?(Path.expand(path), Path.expand(dir) <> "/")
  end

  defp underscored(slug), do: String.replace(slug, "-", "_")

  defp configured_override_dir do
    case Application.get_env(:mydia, :runtime_config) do
      %{plugins: %{override_dir: dir}} -> dir
      _ -> nil
    end
  end

  defp bundled_plugins_dir, do: Application.app_dir(:mydia, "priv/plugins")

  defp deactivate(slug) do
    Host.stop_plugin(slug)
    Registry.unregister(slug)
    :ok
  end

  defp fetch_config(slug) do
    case Settings.get_plugin_config_by_slug(slug) do
      nil -> {:error, Error.new(:not_found, "no installed plugin for slug #{slug}")}
      config -> {:ok, config}
    end
  end

  defp delivery_for(config) do
    case config.settings do
      %{"delivery" => "durable"} -> :durable
      _ -> :inline
    end
  end

  # Recomputes the granted `net:http` for a settings change (never for approval,
  # which goes through effective_grants/2 on the manifest set). The result is
  # everything already granted except the hosts derived from the *previous*
  # setting values, plus the hosts derived from the new ones — so the operator's
  # old URL drops out while every other granted host, static or not, survives. No
  # host the operator has not already approved can enter the grant this way.
  defp recompute_http_grant(config, new_settings) do
    granted = config.granted_capabilities || %{}

    case Map.fetch(granted, "net:http") do
      :error ->
        granted

      {:ok, hosts} ->
        hosts = List.wrap(hosts)
        stale = derived_hosts(config.manifest, config.settings) -- static_hosts(config.manifest)
        kept = hosts -- stale

        granted
        |> Map.put("net:http", Enum.uniq(kept ++ derived_hosts(config.manifest, new_settings)))
        |> put_private_hosts(derived_private_hosts(config.manifest, new_settings))
    end
  end

  # The one grant a manifest and its settings imply: the declared capability set
  # with `net:http` replaced by its effective host list. Both admin approval and
  # bundled reconciliation call this, so an approved grant and a reconciled one
  # can never disagree.
  defp effective_grants(manifest_map, settings) do
    manifest_map
    |> Map.get("capabilities", %{})
    |> put_effective_http(manifest_map, settings)
    |> put_effective_private(manifest_map, settings)
  end

  # `net:private` is never declared in a manifest: it is derived from
  # `allow_private` settings, and only alongside a granted `net:http`, so a
  # plugin cannot reach a private address it was not also allowed to reach.
  defp put_effective_private(map, manifest_map, settings) do
    if Map.has_key?(map, "net:http") do
      put_private_hosts(map, derived_private_hosts(manifest_map, settings))
    else
      map
    end
  end

  # An empty list is left out entirely, so a plugin with no private host carries
  # no `net:private` class at all.
  defp put_private_hosts(map, []), do: Map.delete(map, "net:private")
  defp put_private_hosts(map, hosts), do: Map.put(map, "net:private", hosts)

  defp derived_private_hosts(manifest_map, settings) when is_map(manifest_map) do
    manifest_map
    |> Map.get("settings_schema")
    |> Manifest.private_host_keys()
    |> Enum.map(&Map.get(settings || %{}, &1))
    |> Enum.map(&url_host/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp derived_private_hosts(_manifest_map, _settings), do: []

  # Replaces a capability map's `net:http` with the effective host set, but only
  # when `net:http` is already present — so this never grants a capability that
  # was not declared. Used for the manifest set when approving, when seeding a
  # bundled plugin, and when reconciling one (always via `effective_grants/2`).
  defp put_effective_http(map, manifest_map, settings) do
    if Map.has_key?(map, "net:http") do
      Map.put(map, "net:http", effective_http_hosts(manifest_map, settings))
    else
      map
    end
  end

  # Full-replacement effective allowlist: the manifest's static hosts unioned
  # with the hosts of the operator's host-granting setting values (KTD1).
  defp effective_http_hosts(manifest_map, settings) do
    Enum.uniq(static_hosts(manifest_map) ++ derived_hosts(manifest_map, settings))
  end

  defp static_hosts(manifest_map) when is_map(manifest_map) do
    List.wrap(get_in(manifest_map, ["capabilities", "net:http"]))
  end

  defp static_hosts(_manifest_map), do: []

  # A multi_instance plugin's endpoints are approved per instance; plugin-level
  # settings never widen the plugin-wide grant.
  defp derived_hosts(%{"multi_instance" => true}, _settings), do: []

  defp derived_hosts(manifest_map, settings) when is_map(manifest_map) do
    manifest_map
    |> Map.get("settings_schema")
    |> Manifest.host_granting_keys()
    |> Enum.map(&Map.get(settings || %{}, &1))
    |> Enum.map(&url_host/1)
    |> Enum.reject(&is_nil/1)
  end

  defp derived_hosts(_manifest_map, _settings), do: []

  defp url_host(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> nil
    end
  end

  defp url_host(_), do: nil

  # Rebuilds the registry descriptor from updated config so grant changes take
  # effect immediately. The running pool is left untouched — grants are read from
  # the descriptor on every host-function call (U6), so re-registering is enough.
  defp reregister_descriptor(config) do
    with manifest_map when not is_nil(manifest_map) <- config.manifest,
         {:ok, manifest} <- Manifest.parse(manifest_map) do
      descriptor =
        Plugin.from_manifest(manifest,
          granted_capabilities: config.granted_capabilities || %{},
          enabled: true,
          source: :index,
          delivery: delivery_for(config)
        )

      Registry.register(config.slug, descriptor)
      reload()
      :ok
    else
      error ->
        Logger.warning(
          "could not refresh plugin #{config.slug} after settings change: #{inspect(error)}"
        )

        :ok
    end
  end

  # Must carry every field `Manifest.parse/1` reads: activation re-parses this map.
  @doc false
  def manifest_to_map(%Manifest{} = m) do
    %{
      "slug" => m.slug,
      "name" => m.name,
      "version" => m.version,
      "description" => m.description,
      "author" => m.author,
      "entrypoint" => m.entrypoint,
      "capabilities" => m.capabilities,
      "settings_schema" => m.settings_schema,
      "connection" => m.connection,
      "schedule" => m.schedule,
      "page" => m.page,
      "shelves" => m.shelves,
      "min_host_version" => m.min_host_version,
      "multi_instance" => m.multi_instance,
      "category" => m.category,
      "setup" => m.setup
    }
  end

  defp reload do
    Mydia.Config.Loader.reload()
    :ok
  rescue
    e -> Logger.warning("plugin config reload failed: #{Exception.message(e)}")
  end
end
