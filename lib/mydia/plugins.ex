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

  ## Manifest revisions never widen a grant

  A revised manifest (a built-in upgrade, a reinstalled index package) re-stores
  what the plugin *declares* but leaves the grant exactly as approved, so nothing
  is ever silently widened. The cost is that an approved plugin can end up asking
  for more than it holds and failing `Denied` at the one call site that needed
  the new capability. `needs_reapproval?/1` and `ungranted_capabilities/1` detect
  that state (see `Mydia.Plugins.Capabilities` for the comparison), `activate/1`
  warns about it when the plugin starts, the admin UI badges it, and `approve/2`
  is the way out: it grants the currently requested set.
  """

  require Logger

  alias Mydia.Plugins.Capabilities
  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Host
  alias Mydia.Plugins.HostFunctions
  alias Mydia.Plugins.Index
  alias Mydia.Plugins.Manifest
  alias Mydia.Plugins.Plugin
  alias Mydia.Plugins.Registry
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
        is_map(descriptor) do
      %{
        slug: config.slug,
        name: config.name,
        descriptor: descriptor,
        client_id: Map.get(config.settings || %{}, "client_id") || descriptor["client_id"],
        allowed_hosts: connectable_hosts(config.slug)
      }
    end
  end

  defp connectable_hosts(slug) do
    case get_plugin(slug) do
      {:ok, %Plugin{} = plugin} -> Plugin.granted_http_hosts(plugin)
      _ -> []
    end
  end

  @doc """
  Invokes a plugin for an event, routing by the plugin's delivery mode.

  This is the dispatcher's default invoker. `:inline` plugins run their guest
  handler synchronously through `Mydia.Plugins.Host`. `:durable` plugins (the
  bundled notifier — U10) enqueue a durable Oban delivery job; that branch is
  wired in U10, so until then every plugin is dispatched inline.
  """
  @spec invoke_plugin(Plugin.t(), map()) :: {:ok, term()} | {:error, term()}
  def invoke_plugin(%Plugin{delivery: :durable} = plugin, event) do
    Mydia.Plugins.Notifier.Delivery.enqueue(plugin.slug, build_payload(event))
  end

  def invoke_plugin(%Plugin{} = plugin, event) do
    payload = build_payload(event) |> inject_config(plugin.slug)
    Host.call(plugin.slug, plugin.entrypoint, payload)
  end

  @doc """
  Invokes a plugin's `on-schedule` handler for a scheduled tick (U4).

  Single-flight `:skip`: if a sibling invocation (reactive, inline, or a prior
  schedule) is already running, the tick is a no-op (`{:error, :busy}`), so ticks
  never pile up. The operator settings are injected under `config`, exactly as
  the reactive and durable paths do, so a plugin behaves identically regardless
  of how it was invoked.
  """
  @spec invoke_plugin_schedule(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def invoke_plugin_schedule(slug, opts \\ []) when is_binary(slug) do
    now = Keyword.get(opts, :now, System.system_time(:second))
    payload = inject_config(%{"slug" => slug, "now" => now}, slug)

    Host.call(slug, "on-schedule", payload, handler: :on_schedule, single_flight: :skip)
  end

  # Inject the plugin's operator settings under "config" so the guest sees them
  # on every invocation path (previously only the durable notifier path did).
  defp inject_config(payload, slug) do
    settings =
      case Mydia.Settings.get_plugin_config_by_slug(slug) do
        %{settings: %{} = s} -> s
        _ -> %{}
      end

    Map.put(payload, "config", settings)
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
  `{:error, :not_running}` otherwise.
  """
  @spec test_invoke(String.t(), String.t()) :: :ok | {:error, :not_running}
  def test_invoke(slug, event_type) when is_binary(slug) and is_binary(event_type) do
    case get_plugin(slug) do
      {:ok, %Plugin{} = plugin} ->
        payload = build_payload(synthetic_event(event_type))

        Task.Supervisor.start_child(Mydia.TaskSupervisor, fn ->
          Host.call(plugin.slug, plugin.entrypoint, payload, test_run: true)
        end)

        :ok

      _ ->
        {:error, :not_running}
    end
  end

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
    # Seed the bundled notifier so it shows in the admin UI (pending approval).
    # Gated by the same flag the app uses for boot-time side effects, so the test
    # suite's app boot doesn't write to the shared DB (tests call ensure_bundled/0
    # explicitly when they need it).
    maybe_ensure_bundled()

    Settings.get_db_plugin_configs()
    |> Enum.filter(& &1.enabled)
    |> Enum.each(fn config ->
      case activate(config) do
        {:ok, _} ->
          :ok

        {:error, error} ->
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
  missing slug, refreshes only a changed manifest) and is the reconciliation point
  a long-lived node otherwise lacks. `ensure_bundled/0` runs only once at boot, so
  without this an instance that started before a bundled manifest shipped never
  discovers the new plugin until it restarts.
  """
  @spec maybe_ensure_bundled() :: :ok
  def maybe_ensure_bundled do
    if Application.get_env(:mydia, :start_health_monitors, true), do: ensure_bundled(), else: :ok
  end

  @doc """
  Discovers every bundled plugin shipped in `priv/plugins/` and seeds it disabled
  (pending approval), without copying any wasm bytes into the DB.

  Each `priv/plugins/*.json` manifest is parsed; a slug with no existing config is
  persisted disabled, no grants, `wasm_module: nil` — its bytes resolve from the
  filesystem at activation (see `resolve_artifact/2`). The admin approves and
  configures it through the normal UI (R17: no new core surface). An
  already-installed row's admin state (grants/settings/enabled) is left untouched.

  ## Reconcile (built-in upgrade)

  An install that ran the older copy-into-DB seeding has its bundled row carrying
  stale bytes in `wasm_module`, which the resolver's DB layer would prefer over a
  newer image artifact. Seeding nulls `wasm_module`/`integrity_hash` on any
  `source_url == "bundled"` row so resolution falls through to the filesystem and
  a newer image ships newer code automatically.
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
      %Settings.PluginConfig{} = config -> reconcile_bundled(config, manifest)
    end
  end

  defp seed_bundled(manifest, raw) do
    Settings.create_plugin_config(%{
      slug: manifest.slug,
      name: manifest.name,
      version: manifest.version,
      source_url: "bundled",
      integrity_hash: nil,
      manifest: manifest_to_map(manifest),
      wasm_module: nil,
      granted_capabilities: %{},
      enabled: false,
      settings: bundled_settings(raw)
    })

    :ok
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
  # (built-in upgrade): refresh the stored manifest/metadata, then null any stale
  # DB bytes. Admin state (enabled, grants, settings) is never touched. Non-bundled
  # rows (e.g. an index plugin) are left entirely alone.
  defp reconcile_bundled(%Settings.PluginConfig{source_url: "bundled"} = config, manifest) do
    config
    |> refresh_bundled_manifest(manifest)
    |> reconcile_bundled_artifact()
  end

  defp reconcile_bundled(_config, _manifest), do: :ok

  # Re-store the manifest and display metadata when the bundled definition has
  # changed (e.g. a newly-added `settings_schema`). Runtime privilege is gated by
  # `granted_capabilities`, not by the manifest, so refreshing the declared
  # manifest never widens what an already-approved plugin may actually do.
  defp refresh_bundled_manifest(config, manifest) do
    attrs =
      %{}
      |> put_changed(:manifest, manifest_to_map(manifest), config.manifest)
      |> put_changed(:name, manifest.name, config.name)
      |> put_changed(:version, manifest.version, config.version)

    with true <- attrs != %{},
         {:ok, updated} <- Settings.update_plugin_config(config, attrs) do
      updated
    else
      _ -> config
    end
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
  """
  @spec install(Index.Entry.t(), keyword()) :: {:ok, Plugin.t() | :inactive} | {:error, Error.t()}
  def install(%Index.Entry{} = entry, opts \\ []) do
    grants = Keyword.get(opts, :grants, entry.manifest.capabilities)

    with {:ok, %{wasm: wasm, hash: hash}} <- Index.fetch_package(entry, opts),
         {:ok, config} <- persist_install(entry, wasm, hash, grants) do
      finish_activation(config)
    end
  end

  @doc """
  Approves the full declared capability set for an already-installed plugin and
  activates it.

  Used by the install-then-approve flow (AE1) and by re-approval after a
  capability change — grants never auto-expand, so a manifest that newly requests
  more requires a fresh approval here.
  """
  @spec approve(String.t(), keyword()) :: {:ok, Plugin.t()} | {:error, Error.t()}
  def approve(slug, _opts \\ []) do
    with {:ok, config} <- fetch_config(slug),
         manifest when not is_nil(manifest) <- config.manifest,
         {:ok, config} <-
           Settings.update_plugin_config(config, %{
             granted_capabilities:
               put_effective_http(manifest["capabilities"] || %{}, manifest, config.settings),
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
      if updated.enabled, do: reregister_descriptor(updated)
      {:ok, updated}
    end
  end

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
      {:ok, :revoked}
    end
  end

  @doc "Removes a plugin entirely: deactivates it and deletes its config (R14)."
  @spec remove(String.t()) :: {:ok, :removed} | {:error, Error.t()}
  def remove(slug) do
    with {:ok, config} <- fetch_config(slug),
         {:ok, _} <- Settings.delete_plugin_config(config) do
      deactivate(slug)
      reload()
      {:ok, :removed}
    end
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
  equal versions).
  """
  @spec detect_updates([Settings.PluginConfig.t()], [Index.Entry.t()]) :: [map()]
  def detect_updates(installed, entries) do
    latest_by_slug =
      entries
      |> Enum.group_by(& &1.slug)
      |> Map.new(fn {slug, es} -> {slug, latest_version(es)} end)

    Enum.flat_map(installed, fn config ->
      latest = Map.get(latest_by_slug, config.slug)

      if latest && version_newer?(latest, config.version) do
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
          Logger.warning("update check could not fetch #{source}: #{inspect(error)}")
          []
      end
    end)
  end

  defp latest_version(entries) do
    entries
    |> Enum.map(& &1.version)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort(&(not version_newer?(&2, &1)))
    |> List.first()
  end

  # True when `candidate` is a newer version than `current`. Uses semver when
  # both parse, falling back to string inequality.
  defp version_newer?(_candidate, nil), do: true

  defp version_newer?(candidate, current) do
    case {Version.parse(candidate), Version.parse(current)} do
      {{:ok, c}, {:ok, cur}} -> Version.compare(c, cur) == :gt
      _ -> candidate != current and candidate > current
    end
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

  defp persist_install(entry, wasm, hash, grants) do
    Settings.upsert_plugin_config(%{
      slug: entry.slug,
      name: entry.name,
      version: entry.version,
      source_url: entry.package_url,
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
        err
    end
  end

  # Builds the runtime descriptor from the persisted config + manifest and starts
  # its pool with the gated host-function imports. The wasm bytes are resolved
  # through the layered resolver (override dir → DB blob → bundled priv/plugins).
  defp activate(config) do
    with manifest_map when not is_nil(manifest_map) <- config.manifest,
         {:ok, manifest} <- Manifest.parse(manifest_map),
         :ok <- check_host_version_floor(config.slug, manifest),
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
          Registry.register(config.slug, descriptor)

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
  defp check_host_version_floor(slug, %Manifest{min_host_version: floor}) do
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

  defp host_meets_floor?(floor) do
    case {Version.parse(host_version()), Version.parse(floor)} do
      {{:ok, host}, {:ok, min}} -> Version.compare(host, min) != :lt
      # If either side is unparseable, do not block activation on the floor.
      _ -> true
    end
  end

  defp host_version do
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
      {:error, _} = err -> err
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
  # which goes through put_effective_http/3 on the manifest set). The result is
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

        Map.put(
          granted,
          "net:http",
          Enum.uniq(kept ++ derived_hosts(config.manifest, new_settings))
        )
    end
  end

  # Replaces a capability map's `net:http` with the effective host set, but only
  # when `net:http` is already present — so this never grants a capability the
  # admin did not approve. Used for the manifest set at approve time.
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

  defp manifest_to_map(%Manifest{} = m) do
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
      "schedule" => m.schedule
    }
  end

  defp reload do
    Mydia.Config.Loader.reload()
    :ok
  rescue
    e -> Logger.warning("plugin config reload failed: #{Exception.message(e)}")
  end
end
