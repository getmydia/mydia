defmodule Mydia.Plugins.Manifest do
  @moduledoc """
  Plugin manifest format and capability taxonomy.

  A manifest is the JSON document shipped with a plugin package. It *declares*
  metadata, the events the plugin subscribes to, and the capabilities it wants.
  Parsing validates the manifest and produces a `%Manifest{}`; it never confers
  any capability (grants are server-side — see `Mydia.Plugins.Plugin`).

  ## Format

      {
        "slug": "webhook-notifier",
        "name": "Webhook Notifier",
        "version": "1.0.0",
        "description": "Posts events to a webhook",
        "author": "Mydia",
        "entrypoint": "handle",
        "capabilities": {
          "events:subscribe": ["media_item.added", "download.completed"],
          "net:http": ["discord.com"]
        }
      }

  ## Capability taxonomy

    * `events:subscribe` — the list of event types the plugin reacts to. Each
      must be in the v1 catalog (`event_catalog/0`).
    * `net:http` — the exact hostnames the plugin may contact. **No wildcards**
      (a wildcard is a DNS-subdomain exfiltration channel — KTD5).
    * `data:read` — scoped read namespaces (e.g. `media_item`). Each namespace
      must be in the v1 read catalog (`data_namespaces/0`); the host honors it
      via the `data_read` host function (U6), which returns a curated read-only
      projection — never raw rows or secrets.
    * `surfaces:write` — write-back surfaces. **Reserved, not implemented in v1.**

  To avoid an approve-but-no-runtime gap (KTD8), a v1 manifest declaring a
  reserved-but-unimplemented class (only `surfaces:write` remains reserved) is
  rejected at parse time with a clear "capability not available in this version"
  error — the admin is never asked to approve a capability no host function
  honors.

  ## Settings schema

  An optional top-level `settings_schema` declares the operator-editable config
  fields a plugin exposes. Each field is an object with `key`, `type`
  (`string | url | secret | enum | text`, where `text` renders as a multiline
  textarea), and optional `label`, `required`, and (for `enum`) `options`. A
  `url` field may carry `grants_host: true`, which marks it as **host-granting**:
  the host of the operator-configured value is added to the plugin's effective
  `net:http` allowlist at config time (see `Mydia.Plugins` host-grant
  recomputation). This lets a shared plugin reach a server the operator owns
  without the hostname ever appearing in the manifest, while the host — never the
  guest — computes the grant.

  ## Host version floor

  An optional top-level `min_host_version` (a semantic version) declares the
  lowest Mydia version the plugin supports. `Mydia.Plugins` refuses to activate a
  plugin whose floor exceeds the running host with a clear "requires mydia ≥ X"
  message, before instantiation — the friendly wrapper over wasmtime's hard
  component link-time refusal (the WIT package version is the ABI version).
  Absent means no floor (back-compat).

  A field may also carry `visible_when`, a map of `controlling_key => value`
  (value a string or list of strings) gating its visibility in the settings UI on
  another field's current value — e.g. `"visible_when": {"target": "ntfy"}` shows
  the field only when the `target` setting is `ntfy`. Each referenced key must
  name a sibling field. This is presentation only; the host does not enforce it.
  """

  alias Mydia.Plugins.Error

  @type t :: %__MODULE__{
          slug: String.t(),
          name: String.t(),
          version: String.t(),
          description: String.t() | nil,
          author: String.t() | nil,
          entrypoint: String.t(),
          events: [String.t()],
          capabilities: %{optional(String.t()) => [String.t()]},
          settings_schema: [map()],
          connection: map() | nil,
          schedule: map() | nil,
          min_host_version: String.t() | nil
        }

  defstruct slug: nil,
            name: nil,
            version: nil,
            description: nil,
            author: nil,
            entrypoint: "handle",
            events: [],
            capabilities: %{},
            settings_schema: [],
            connection: nil,
            schedule: nil,
            min_host_version: nil

  # v1 event catalog (KTD3): a curated subset of existing event `type` strings
  # dispatched off the "events:all" bus. This is a deliberate, narrower public
  # contract than `Mydia.Events.Presentation.known_types/0` — not every
  # registered event is safe or useful to hand to a plugin. The subset
  # invariant (every entry here must also be in the presentation registry) is
  # enforced by a test in `test/mydia/events/presentation_test.exs`, not by
  # code, so renaming or removing a type below must be checked against that
  # registry by hand.
  @event_catalog ~w(
    media_item.added
    media_item.updated
    media_item.removed
    media_file.imported
    download.completed
    download.failed
    playback.started
    playback.progressed
    playback.paused
    playback.finished
    playback.unwatched
  )

  # All taxonomy classes (reserved + implemented). The schema/approval UI know
  # all four so they need no breaking change when the reserved ones land.
  @known_classes ~w(events:subscribe net:http data:read surfaces:write state:kv users:connections schedule:interval)

  # Implemented capability classes. `data:read` is honored by data-read/data-list;
  # `state:kv` by the kv-* host functions (U3); `users:connections` by
  # connections-list + the connect flow (U7); `schedule:interval` by the
  # PluginScheduler tick (U4); `surfaces:write` by ensure-watched (U6).
  @available_classes ~w(events:subscribe net:http data:read state:kv users:connections schedule:interval surfaces:write)

  # The value vocabulary for `surfaces:write` — the curated write surfaces a
  # plugin may target. Only `playback:watched` (the ensure-watched host function)
  # is honored in this version.
  @write_surfaces ~w(playback:watched)

  # The lowest interval (minutes) a scheduled plugin may request — a floor so a
  # misconfigured manifest can't tick the host to death.
  @min_schedule_interval 5

  # Read catalog: the resource namespaces `data:read` may scope to. `media_item`
  # is served by both `data-read` (single) and `data-list` (enumerate);
  # `playback_progress` (U5) is a `data-list`-only per-user watch projection,
  # consent-scoped to users with an active connection to the calling plugin.
  @data_namespaces ~w(media_item playback_progress)

  # Field types a `settings_schema` entry may declare. `text` renders as a
  # multiline textarea (used for template fields); otherwise like `string`.
  @setting_types ~w(string url secret enum text)

  @doc """
  Returns the v1 event catalog: the plugin subscription contract for
  `events:subscribe` (allowed values).

  This is a deliberate subset of `Mydia.Events.Presentation.known_types/0`,
  not a mirror of it — plugins only ever see the events curated for the
  public contract.
  """
  @spec event_catalog() :: [String.t()]
  def event_catalog, do: @event_catalog

  @doc "Returns every capability class name (implemented and reserved)."
  @spec known_classes() :: [String.t()]
  def known_classes, do: @known_classes

  @doc "Returns the capability classes a host function honors in this version."
  @spec available_classes() :: [String.t()]
  def available_classes, do: @available_classes

  @doc "Returns the v1 `data:read` namespaces (allowed scoped-read values)."
  @spec data_namespaces() :: [String.t()]
  def data_namespaces, do: @data_namespaces

  @doc """
  Parses and validates a manifest from a JSON string or an already-decoded map.

  Returns `{:ok, %Manifest{}}` or `{:error, %Mydia.Plugins.Error{}}`. Parsing
  confers no capability (R5).
  """
  @spec parse(String.t() | map()) :: {:ok, t()} | {:error, Error.t()}
  def parse(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> parse(map)
      {:ok, _} -> {:error, Error.new(:invalid_manifest, "manifest must be a JSON object")}
      {:error, _} -> {:error, Error.new(:invalid_manifest, "manifest is not valid JSON")}
    end
  end

  def parse(map) when is_map(map) do
    capabilities = Map.get(map, "capabilities", %{})
    settings_schema = Map.get(map, "settings_schema", [])

    connection = Map.get(map, "connection")
    schedule = Map.get(map, "schedule")

    with :ok <- validate_required(map),
         {:ok, capabilities} <- validate_capabilities(capabilities),
         {:ok, settings_schema} <- validate_settings_schema(settings_schema),
         :ok <- validate_connection(connection, capabilities),
         :ok <- validate_schedule(schedule, capabilities),
         :ok <- validate_min_host_version(Map.get(map, "min_host_version")) do
      {:ok,
       %__MODULE__{
         slug: map["slug"],
         name: map["name"],
         version: map["version"],
         description: map["description"],
         author: map["author"],
         entrypoint: Map.get(map, "entrypoint", "handle"),
         events: Map.get(capabilities, "events:subscribe", []),
         capabilities: capabilities,
         settings_schema: settings_schema,
         connection: connection,
         schedule: schedule,
         min_host_version: Map.get(map, "min_host_version")
       }}
    end
  end

  @doc """
  Returns the schedule interval in minutes a manifest declares, or `nil` when it
  declares no schedule. Accepts a `%Manifest{}` or a raw schedule map.
  """
  @spec schedule_interval_minutes(t() | map() | nil) :: pos_integer() | nil
  def schedule_interval_minutes(%__MODULE__{schedule: schedule}),
    do: schedule_interval_minutes(schedule)

  def schedule_interval_minutes(%{"interval_minutes" => n}) when is_integer(n), do: n
  def schedule_interval_minutes(_), do: nil

  @doc "The lowest schedule interval (minutes) the host permits."
  @spec min_schedule_interval() :: pos_integer()
  def min_schedule_interval, do: @min_schedule_interval

  @doc """
  Returns the host-granting field maps a manifest declares — `url` fields with
  `grants_host: true`. Accepts either a `%Manifest{}` or a raw `settings_schema`
  list (as stored on a persisted plugin config), so callers reading the JSON
  manifest map do not need to re-parse. The single source of truth for "which
  settings grant a host"; see `host_granting_keys/1`.
  """
  @spec host_granting_fields(t() | [map()] | nil) :: [map()]
  def host_granting_fields(%__MODULE__{settings_schema: schema}), do: host_granting_fields(schema)

  def host_granting_fields(schema) when is_list(schema) do
    Enum.filter(
      schema,
      &(Map.get(&1, "type") == "url" and Map.get(&1, "grants_host") == true)
    )
  end

  def host_granting_fields(_), do: []

  @doc """
  Returns the setting keys a manifest declares host-granting. Thin projection of
  `host_granting_fields/1` to the field `key`.
  """
  @spec host_granting_keys(t() | [map()] | nil) :: [String.t()]
  def host_granting_keys(schema_or_manifest) do
    schema_or_manifest |> host_granting_fields() |> Enum.map(&Map.get(&1, "key"))
  end

  # ── Validation ──────────────────────────────────────────────────────────

  defp validate_required(map) do
    missing = Enum.filter(~w(slug name version), &blank?(Map.get(map, &1)))

    case missing do
      [] ->
        :ok

      fields ->
        {:error,
         Error.new(:invalid_manifest, "missing required fields: #{Enum.join(fields, ", ")}")}
    end
  end

  defp validate_capabilities(capabilities) when not is_map(capabilities) do
    {:error, Error.new(:invalid_manifest, "capabilities must be an object")}
  end

  defp validate_capabilities(capabilities) when capabilities == %{} do
    {:error, Error.new(:invalid_manifest, "a plugin must declare at least one capability")}
  end

  defp validate_capabilities(capabilities) do
    with :ok <- validate_classes(Map.keys(capabilities)),
         :ok <- validate_events(Map.get(capabilities, "events:subscribe")),
         :ok <- validate_http_hosts(Map.get(capabilities, "net:http")),
         :ok <- validate_data_namespaces(Map.get(capabilities, "data:read")),
         :ok <- validate_surfaces(Map.get(capabilities, "surfaces:write")) do
      {:ok, capabilities}
    end
  end

  defp validate_surfaces(nil), do: :ok

  defp validate_surfaces(surfaces) when not is_list(surfaces),
    do: {:error, Error.new(:invalid_manifest, "surfaces:write must be a list of surfaces")}

  defp validate_surfaces([]),
    do: {:error, Error.new(:invalid_manifest, "surfaces:write must not be empty")}

  defp validate_surfaces(surfaces) do
    case Enum.find(surfaces, &(&1 not in @write_surfaces)) do
      nil -> :ok
      bad -> {:error, Error.new(:invalid_manifest, "unknown surfaces:write surface: #{bad}")}
    end
  end

  defp validate_classes(classes) do
    cond do
      unknown = Enum.find(classes, &(&1 not in @known_classes)) ->
        {:error, Error.new(:invalid_manifest, "unknown capability class: #{unknown}")}

      reserved = Enum.find(classes, &(&1 not in @available_classes)) ->
        {:error,
         Error.new(
           :capability_unavailable,
           "capability not available in this version: #{reserved}"
         )}

      "events:subscribe" not in classes ->
        {:error, Error.new(:invalid_manifest, "a plugin must declare events:subscribe")}

      true ->
        :ok
    end
  end

  defp validate_events(nil), do: :ok

  defp validate_events(events) when not is_list(events),
    do: {:error, Error.new(:invalid_manifest, "events:subscribe must be a list")}

  defp validate_events([]),
    do: {:error, Error.new(:invalid_manifest, "events:subscribe must not be empty")}

  defp validate_events(events) do
    case Enum.find(events, &(&1 not in @event_catalog)) do
      nil -> :ok
      bad -> {:error, Error.new(:invalid_manifest, "event not in v1 catalog: #{bad}")}
    end
  end

  defp validate_http_hosts(nil), do: :ok

  defp validate_http_hosts(hosts) when not is_list(hosts),
    do: {:error, Error.new(:invalid_manifest, "net:http must be a list of hostnames")}

  defp validate_http_hosts(hosts) do
    cond do
      bad = Enum.find(hosts, &(not is_binary(&1) or blank?(&1))) ->
        {:error, Error.new(:invalid_manifest, "net:http hostname is blank: #{inspect(bad)}")}

      wild = Enum.find(hosts, &String.contains?(&1, "*")) ->
        {:error,
         Error.new(
           :invalid_manifest,
           "net:http hostname must be exact, no wildcards: #{wild}"
         )}

      bad = Enum.find(hosts, &(&1 != String.trim(&1))) ->
        {:error,
         Error.new(
           :invalid_manifest,
           "net:http hostname must not have leading/trailing whitespace: #{inspect(bad)}"
         )}

      bad = Enum.find(hosts, &(not bare_hostname?(&1))) ->
        {:error,
         Error.new(
           :invalid_manifest,
           "net:http must be a bare hostname (no scheme, port, path, or userinfo): #{bad}"
         )}

      true ->
        :ok
    end
  end

  # The net:http gate (`Mydia.Plugins.Net.Gate`) matches a request's `URI.host`
  # against these values exactly, so anything that can't appear in a bare host —
  # a scheme prefix, a `:port`, a `/path`, or `user@` userinfo — can never match
  # and would surface as a confusing `capability_denied` at request time. Reject
  # those forms at parse time so the manifest fails fast with a clear error.
  defp bare_hostname?(host) do
    not String.contains?(host, [":", "/", "@", " "])
  end

  defp validate_data_namespaces(nil), do: :ok

  defp validate_data_namespaces(namespaces) when not is_list(namespaces),
    do: {:error, Error.new(:invalid_manifest, "data:read must be a list of namespaces")}

  defp validate_data_namespaces([]),
    do: {:error, Error.new(:invalid_manifest, "data:read must not be empty")}

  defp validate_data_namespaces(namespaces) do
    case Enum.find(namespaces, &(&1 not in @data_namespaces)) do
      nil ->
        :ok

      bad ->
        {:error, Error.new(:invalid_manifest, "data:read namespace not in v1 catalog: #{bad}")}
    end
  end

  # An optional `connection` descriptor declares a host-run OAuth device flow
  # (U7/U8): a `type` and the URL templates the host drives. Every URL — code
  # request, poll, and the user-facing verification link — must sit on the
  # plugin's declared net:http hosts, so the verification URL rendered in trusted
  # host UI can never become a phishing surface, and the host never fetches an
  # un-allowlisted endpoint.
  defp validate_connection(nil, _capabilities), do: :ok

  defp validate_connection(conn, _capabilities) when not is_map(conn),
    do: {:error, Error.new(:invalid_manifest, "connection must be an object")}

  defp validate_connection(conn, capabilities) do
    hosts = Map.get(capabilities, "net:http", [])

    with :ok <- validate_connection_type(Map.get(conn, "type")),
         :ok <- validate_connection_url(conn, "code_url", hosts, true),
         :ok <- validate_connection_url(conn, "poll_url", hosts, true) do
      validate_connection_url(conn, "verification_url", hosts, false)
    end
  end

  defp validate_connection_type("oauth_device"), do: :ok

  defp validate_connection_type(other),
    do:
      {:error,
       Error.new(
         :invalid_manifest,
         "connection.type must be \"oauth_device\", got: #{inspect(other)}"
       )}

  defp validate_connection_url(conn, key, hosts, required?) do
    case Map.get(conn, key) do
      nil ->
        if required?,
          do: {:error, Error.new(:invalid_manifest, "connection.#{key} is required")},
          else: :ok

      url when is_binary(url) ->
        host = URI.parse(url).host

        cond do
          is_nil(host) ->
            {:error, Error.new(:invalid_manifest, "connection.#{key} is not a valid URL: #{url}")}

          host in hosts ->
            :ok

          true ->
            {:error,
             Error.new(
               :invalid_manifest,
               "connection.#{key} host #{host} must be declared in net:http"
             )}
        end

      _ ->
        {:error, Error.new(:invalid_manifest, "connection.#{key} must be a string URL")}
    end
  end

  # An optional `schedule` (`{"interval_minutes": N}`) opts the plugin into the
  # host's fixed-interval tick (U4). The interval is floored at
  # `@min_schedule_interval`, and the plugin must declare the `schedule:interval`
  # capability so the schedule shows at approval — a plugin can't get a clock
  # without the admin seeing it.
  defp validate_schedule(nil, _capabilities), do: :ok

  defp validate_schedule(schedule, _capabilities) when not is_map(schedule),
    do: {:error, Error.new(:invalid_manifest, "schedule must be an object")}

  defp validate_schedule(schedule, capabilities) do
    if Map.has_key?(capabilities, "schedule:interval") do
      validate_schedule_interval(Map.get(schedule, "interval_minutes"))
    else
      {:error,
       Error.new(
         :invalid_manifest,
         "a plugin with a schedule must declare the schedule:interval capability"
       )}
    end
  end

  defp validate_schedule_interval(n) when is_integer(n) and n >= @min_schedule_interval, do: :ok

  defp validate_schedule_interval(n) when is_integer(n),
    do:
      {:error,
       Error.new(
         :invalid_manifest,
         "schedule.interval_minutes must be at least #{@min_schedule_interval}, got: #{n}"
       )}

  defp validate_schedule_interval(_),
    do: {:error, Error.new(:invalid_manifest, "schedule.interval_minutes must be an integer")}

  # An optional `min_host_version` declares the lowest Mydia version the plugin
  # supports — the floor `Mydia.Plugins` enforces at activation (R7). It must be a
  # valid semantic version when present; absent means "no floor" (back-compat).
  defp validate_min_host_version(nil), do: :ok

  defp validate_min_host_version(value) when is_binary(value) do
    case Version.parse(value) do
      {:ok, _} ->
        :ok

      :error ->
        {:error,
         Error.new(:invalid_manifest, "min_host_version must be a semantic version: #{value}")}
    end
  end

  defp validate_min_host_version(_),
    do: {:error, Error.new(:invalid_manifest, "min_host_version must be a string")}

  defp validate_settings_schema(nil), do: {:ok, []}

  defp validate_settings_schema(schema) when not is_list(schema),
    do: {:error, Error.new(:invalid_manifest, "settings_schema must be a list")}

  defp validate_settings_schema(schema) do
    with :ok <- validate_each_setting(schema),
         :ok <- validate_unique_setting_keys(schema),
         :ok <- validate_visible_when_keys(schema) do
      {:ok, schema}
    end
  end

  defp validate_each_setting(schema) do
    Enum.reduce_while(schema, :ok, fn field, :ok ->
      case validate_setting_field(field) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_setting_field(field) when not is_map(field),
    do: {:error, Error.new(:invalid_manifest, "settings_schema field must be an object")}

  defp validate_setting_field(field) do
    key = Map.get(field, "key")
    type = Map.get(field, "type")

    cond do
      blank?(key) ->
        {:error, Error.new(:invalid_manifest, "settings_schema field key is blank")}

      type not in @setting_types ->
        {:error,
         Error.new(:invalid_manifest, "settings_schema field #{key} has unknown type: #{type}")}

      Map.get(field, "grants_host") == true and type != "url" ->
        {:error,
         Error.new(:invalid_manifest, "grants_host is only allowed on url fields: #{key}")}

      type == "enum" and not valid_options?(Map.get(field, "options")) ->
        {:error,
         Error.new(
           :invalid_manifest,
           "enum setting #{key} must declare a non-empty options list"
         )}

      not valid_visible_when?(Map.get(field, "visible_when")) ->
        {:error,
         Error.new(
           :invalid_manifest,
           "visible_when on #{key} must be an object mapping a setting key to a string or list of strings"
         )}

      true ->
        :ok
    end
  end

  # `visible_when` (optional) gates a field's visibility in the settings UI on
  # the value of another setting: a map of `controlling_key => value`, where
  # value is a string or a non-empty list of strings. Absent means always shown.
  defp valid_visible_when?(nil), do: true

  defp valid_visible_when?(map) when is_map(map) and map_size(map) > 0 do
    Enum.all?(map, fn
      {k, v} when is_binary(k) -> valid_visible_when_value?(v)
      _ -> false
    end)
  end

  defp valid_visible_when?(_), do: false

  defp valid_visible_when_value?(v) when is_binary(v), do: true

  defp valid_visible_when_value?(v) when is_list(v) and v != [],
    do: Enum.all?(v, &is_binary/1)

  defp valid_visible_when_value?(_), do: false

  defp valid_options?(options) when is_list(options) and options != [],
    do: Enum.all?(options, &(is_binary(&1) and not blank?(&1)))

  defp valid_options?(_), do: false

  defp validate_unique_setting_keys(schema) do
    keys = Enum.map(schema, &Map.get(&1, "key"))

    if length(Enum.uniq(keys)) == length(keys) do
      :ok
    else
      {:error, Error.new(:invalid_manifest, "settings_schema keys must be unique")}
    end
  end

  # Every key referenced by a `visible_when` must name a sibling field, so the
  # UI can resolve the controlling value. (Shape is checked per-field above.)
  defp validate_visible_when_keys(schema) do
    keys = MapSet.new(schema, &Map.get(&1, "key"))

    schema
    |> Enum.flat_map(fn field ->
      case Map.get(field, "visible_when") do
        m when is_map(m) -> Map.keys(m)
        _ -> []
      end
    end)
    |> Enum.find(&(&1 not in keys))
    |> case do
      nil ->
        :ok

      missing ->
        {:error,
         Error.new(:invalid_manifest, "visible_when references unknown setting key: #{missing}")}
    end
  end

  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false
end
