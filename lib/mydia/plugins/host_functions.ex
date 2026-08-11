defmodule Mydia.Plugins.HostFunctions do
  @moduledoc """
  Typed WIT host imports exposed to component guests (U4).

  Host functions are the plugin platform's capability model: a guest can only
  affect the outside world by calling an imported host function, and each one
  enforces the plugin's **server-side** grant (deny-by-default) before doing any
  work. Grants are resolved from the runtime registry on *every* call, so a
  revoked capability takes effect immediately (a plugin can never widen its own
  grant — KTD6).

  ## Component import ABI (1.1)

  Imports live under the `"mydia:plugin/host@1.2.0"` interface namespace and
  receive/return **typed WIT records** — no linear-memory marshalling. Wasmex
  hands each import closure the decoded record (atom-keyed map; `option<T>` as
  `{:some, v}` / `:none`; `list<tuple>` as `[{k, v}]`) and marshals the closure's
  return value back across the boundary. The 1.0 functions —

    * `http-request(outbound-request) -> result<outbound-response, host-error>`
    * `data-read(data-request) -> result<read-result, host-error>`
    * `log(string, string)` — ungated, fire-and-forget

  are joined in 1.1 by `kv-get/set/delete`, `data-list`, `ensure-watched`,
  `connections-list`, and `connection-request` (each capability-gated).

  A closure must return exactly the WIT-declared shape: `{:ok, record}` /
  `{:error, host-error}` for the `result` functions. A wrong-typed return can
  panic the wasmex NIF, so every closure is wrapped in a shim
  (`typed_result/1`) that converts any raise into a well-formed `internal`
  error variant rather than letting a bad value reach the boundary.

  ## Imports are built per invocation

  Unlike the core-wasm host (one shared imports map), the component host builds
  the imports map per invocation through `imports_for/2`, which returns a builder
  `(invocation_ctx -> map)`. The closures capture the invocation context
  directly, so a guest `log` line correlates to its run without a shared
  registry; the per-invocation log-line counter lives in the builder closure.
  """

  require Logger

  alias Mydia.Media
  alias Mydia.Playback
  alias Mydia.Plugins
  alias Mydia.Plugins.Connections
  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Kv
  alias Mydia.Plugins.Logs
  alias Mydia.Plugins.Matcher
  alias Mydia.Plugins.Net.Gate
  alias Mydia.Plugins.Plugin

  # Hard page cap for data-list — a guest may request fewer but never more.
  @data_list_page_cap 200

  # The WIT host interface namespace. The version suffix is the ABI version.
  # wasmtime serves this 1.1 superset to a 1.0 guest (which imports
  # `host@1.0.0`) via component semver matching, so older guests keep working.
  @namespace "mydia:plugin/host@1.2.0"

  # Per-invocation guest log-line cap. `log` is ungated, so a buggy or hostile
  # guest could spam it in a loop and flood plugin_logs before retention fires.
  # Past the cap we drop further lines and emit one sentinel.
  @log_line_cap 1000

  @doc """
  Builds the per-invocation imports builder for a plugin pool.

  Returns a 1-arity function `(invocation_ctx -> imports_map)` that
  `Mydia.Plugins.Host` invokes for each call, so the `log` closure can capture
  the run's `invocation_id`/`test_run` directly. The closures capture `slug`; the
  current grants are looked up per call, so revocation is honored without
  restarting the pool. `gate_opts` are host-side options forwarded to the gate
  (e.g. the `:allow_private`/`:resolver` test seams) — production passes none, so
  a guest can never influence them.
  """
  @spec imports_for(String.t(), keyword()) :: (map() -> map())
  def imports_for(slug, gate_opts \\ []) when is_binary(slug) do
    fn ctx ->
      %{
        @namespace => %{
          "http-request" => {:fn, http_import(slug, gate_opts)},
          "data-read" => {:fn, data_import(slug)},
          "log" => {:fn, log_import(slug, ctx)},
          # ── 1.1.0 imports (U2 contract; bodies land in U3/U5/U6/U7) ──
          "kv-get" => {:fn, kv_get_import(slug)},
          "kv-set" => {:fn, kv_set_import(slug)},
          "kv-delete" => {:fn, kv_delete_import(slug)},
          "data-list" => {:fn, data_list_import(slug)},
          "ensure-watched" => {:fn, ensure_watched_import(slug)},
          "ensure-favorite" => {:fn, ensure_favorite_import(slug)},
          "connections-list" => {:fn, connections_list_import(slug)},
          "connection-request" => {:fn, connection_request_import(slug, gate_opts)}
        }
      }
    end
  end

  # ── 1.1.0 import closures ───────────────────────────────────────────────────
  #
  # Every new import is wired here so a 1.1 guest instantiates (wasmtime requires
  # the host to provide the full imported interface). Each enforces its grant
  # deny-by-default; the post-grant body is filled in by the owning unit. Until
  # then a granted call returns an `internal` "not implemented" error — no plugin
  # is granted these classes before U9, which lands after U3–U7.

  defp kv_get_import(slug) do
    fn key ->
      typed_result(fn ->
        with {:ok, plugin} <- Plugins.get_plugin(slug) do
          kv_get(plugin, key)
        end
      end)
    end
  end

  defp kv_set_import(slug) do
    fn key, value ->
      typed_result(fn ->
        with {:ok, plugin} <- Plugins.get_plugin(slug) do
          kv_set(plugin, key, value)
        end
      end)
    end
  end

  defp kv_delete_import(slug) do
    fn key ->
      typed_result(fn ->
        with {:ok, plugin} <- Plugins.get_plugin(slug) do
          kv_delete(plugin, key)
        end
      end)
    end
  end

  defp data_list_import(slug) do
    fn req ->
      typed_result(fn ->
        with {:ok, plugin} <- Plugins.get_plugin(slug) do
          data_list(plugin, req)
        end
      end)
    end
  end

  defp ensure_watched_import(slug) do
    fn target ->
      typed_result(fn ->
        with {:ok, plugin} <- Plugins.get_plugin(slug) do
          ensure_watched(plugin, target)
        end
      end)
    end
  end

  defp ensure_favorite_import(slug) do
    fn target ->
      typed_result(fn ->
        with {:ok, plugin} <- Plugins.get_plugin(slug) do
          ensure_favorite(plugin, target)
        end
      end)
    end
  end

  defp connections_list_import(slug) do
    fn ->
      typed_result(fn ->
        with {:ok, plugin} <- Plugins.get_plugin(slug) do
          connections_list(plugin)
        end
      end)
    end
  end

  defp connection_request_import(slug, gate_opts) do
    fn connection_id, req ->
      typed_result(fn ->
        with {:ok, plugin} <- Plugins.get_plugin(slug),
             {:ok, resp} <-
               connection_request(plugin, connection_id, from_outbound_request(req), gate_opts) do
          {:ok, to_outbound_response(resp)}
        end
      end)
    end
  end

  # ── http-request import ────────────────────────────────────────────────────

  defp http_import(slug, gate_opts) do
    fn req ->
      typed_result(fn ->
        with {:ok, plugin} <- Plugins.get_plugin(slug),
             {:ok, resp} <- http_request(plugin, from_outbound_request(req), gate_opts) do
          {:ok, to_outbound_response(resp)}
        end
      end)
    end
  end

  # WIT outbound-request record -> the string-key request map the gated logic
  # expects. `headers` arrives as a list of {k, v} tuples; the gate wants a map.
  defp from_outbound_request(req) do
    %{
      "url" => Map.get(req, :url, ""),
      "method" => Map.get(req, :method, "GET"),
      "headers" => req |> Map.get(:headers, []) |> Map.new(),
      "body" => from_option(Map.get(req, :body))
    }
  end

  defp to_outbound_response(%{"status" => status} = resp) do
    %{
      status: status,
      ok: Map.get(resp, "ok", false),
      body: to_option(Map.get(resp, "body")),
      "body-encoding": to_option(Map.get(resp, "body_encoding"))
    }
  end

  # ── data-read import ───────────────────────────────────────────────────────

  defp data_import(slug) do
    fn req ->
      typed_result(fn ->
        with {:ok, plugin} <- Plugins.get_plugin(slug),
             {:ok, projection} <- data_read(plugin, from_data_request(req)) do
          {:ok, {:"media-item", to_media_item(projection)}}
        end
      end)
    end
  end

  defp from_data_request(req) do
    %{"resource" => Map.get(req, :namespace, ""), "id" => Map.get(req, :id, "")}
  end

  # String-key projection map -> the WIT media-item record (kebab atom keys,
  # option-wrapped optionals). Field set mirrors project_media_item/1 exactly.
  defp to_media_item(p) do
    %{
      id: get(p, "id", ""),
      "item-type": get(p, "type", ""),
      title: get(p, "title", ""),
      "original-title": to_option(get(p, "original_title")),
      year: to_option(get(p, "year")),
      "tmdb-id": to_option(get(p, "tmdb_id")),
      "tvdb-id": to_option(get(p, "tvdb_id")),
      "imdb-id": to_option(get(p, "imdb_id")),
      overview: to_option(get(p, "overview")),
      tagline: to_option(get(p, "tagline")),
      runtime: to_option(get(p, "runtime")),
      genres: get(p, "genres") || [],
      "poster-path": to_option(get(p, "poster_path")),
      "backdrop-path": to_option(get(p, "backdrop_path")),
      rating: to_option(get(p, "rating"))
    }
  end

  defp get(map, key, default \\ nil), do: Map.get(map, key, default)

  # ── log import (ungated) ───────────────────────────────────────────────────

  # `log(level, message)` is ungated — every guest may emit diagnostics with no
  # capability grant (R1). Built per invocation, so `ctx` correlates the line to
  # its run and the counter (captured here) caps lines within the invocation. It
  # returns the empty list (the WIT function has no result) and never raises into
  # the guest.
  defp log_import(slug, ctx) do
    counter = :counters.new(1, [:write_concurrency])

    fn level, message ->
      try do
        record_guest_line(slug, ctx, counter, level, message)
        []
      rescue
        e ->
          Logger.warning("plugin log for #{slug} raised: #{Exception.message(e)}")
          []
      end
    end
  end

  defp record_guest_line(slug, ctx, counter, level, message) do
    :counters.add(counter, 1, 1)
    n = :counters.get(counter, 1)

    cond do
      n <= @log_line_cap ->
        write_guest_line(slug, ctx, level, message)

      n == @log_line_cap + 1 ->
        Logs.create_async(%{
          slug: slug,
          invocation_id: ctx[:invocation_id],
          source: :host,
          level: :warn,
          message: "log limit reached (#{@log_line_cap} lines) — further guest lines dropped",
          test_run: ctx[:test_run] || false
        })

      true ->
        :ok
    end
  end

  defp write_guest_line(slug, ctx, level, message) do
    Logs.create_async(%{
      slug: slug,
      invocation_id: ctx[:invocation_id],
      source: :guest,
      level: normalize_level(level),
      message: to_string(message),
      test_run: ctx[:test_run] || false
    })
  end

  defp normalize_level(level) when is_binary(level) do
    case String.downcase(level) do
      "debug" -> :debug
      "info" -> :info
      "warn" -> :warn
      "warning" -> :warn
      "error" -> :error
      _ -> :info
    end
  end

  defp normalize_level(_), do: :info

  # ── Return-type shim ───────────────────────────────────────────────────────

  # Guarantees the import returns a well-formed WIT `result`: maps an Error to
  # the matching host-error variant, and catches any raise so a wrong-typed value
  # never reaches the boundary (which can NIF-panic).
  defp typed_result(fun) do
    case fun.() do
      {:ok, record} -> {:ok, record}
      {:error, %Error{} = err} -> {:error, host_error(err)}
    end
  rescue
    e ->
      Logger.warning("host function raised: #{Exception.message(e)}")
      {:error, {:internal, "host function error"}}
  end

  defp host_error(%Error{type: type, message: message}) do
    tag =
      case type do
        :capability_denied -> :denied
        :invalid_request -> :"invalid-request"
        :invalid_output -> :"invalid-request"
        :invalid_url -> :"invalid-request"
        :not_found -> :"not-found"
        :network -> :network
        :network_error -> :network
        :timeout -> :network
        :too_large -> :network
        :blocked -> :network
        _ -> :internal
      end

    {tag, to_string(message)}
  end

  # ── option<T> marshalling ──────────────────────────────────────────────────

  defp to_option(nil), do: :none
  defp to_option(value), do: {:some, value}

  defp from_option({:some, value}), do: value
  defp from_option(:none), do: nil
  defp from_option(nil), do: nil

  # ── http_request (net:http) ───────────────────────────────────────────────

  @doc """
  Performs a gated outbound HTTP request on behalf of `plugin`.

  Enforces the plugin's `net:http` grant (deny-by-default) and routes through
  `Mydia.Plugins.Net.Gate`. `request` is the string-key map adapted from the WIT
  `outbound-request`: `%{"url" => url, "method" => "POST", "headers" => %{},
  "body" => "..."}`.

  `opts` are host-side only (e.g. the `:allow_private` test seam) — never derived
  from the guest request.
  """
  @spec http_request(Plugin.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def http_request(%Plugin{} = plugin, request, opts \\ []) do
    with :ok <- require_capability(plugin, "net:http"),
         {:ok, url} <- fetch_string(request, "url"),
         :ok <- require_granted_host(plugin, url) do
      hosts = Plugin.granted_http_hosts(plugin)

      gate_opts =
        [
          allowed_hosts: hosts,
          slug: plugin.slug,
          method: Map.get(request, "method", "GET"),
          headers: Map.get(request, "headers", %{}),
          body: Map.get(request, "body")
        ] ++ Keyword.take(opts, [:allow_private, :resolver, :max_bytes, :timeout])

      case Gate.request(url, gate_opts) do
        {:ok, resp} -> {:ok, http_response_map(resp)}
        {:error, _} = err -> err
      end
    end
  end

  # A host the manifest declares but the grant does not hold is the stale-grant
  # case again — the gate would deny it with a bare "not on the allowlist", which
  # reads as a plugin bug rather than as pending re-approval. Every other host
  # (including one the manifest never declared) falls through to the gate
  # untouched, so this narrows nothing and only replaces the message.
  defp require_granted_host(plugin, url) do
    case URI.parse(url).host do
      host when is_binary(host) and host != "" ->
        host = String.downcase(host)
        declared? = host in downcased(Map.get(plugin.capabilities, "net:http"))
        granted? = host in downcased(Plugin.granted_http_hosts(plugin))

        if declared? and not granted?,
          do: {:error, denial(plugin, "net:http host #{host}", true)},
          else: :ok

      _ ->
        :ok
    end
  end

  defp downcased(hosts), do: hosts |> List.wrap() |> Enum.map(&String.downcase/1)

  defp http_response_map(%{status: status, body: body}) do
    base = %{"status" => status, "ok" => status in 200..299}

    if String.valid?(body) do
      Map.put(base, "body", body)
    else
      Map.put(base, "body_encoding", "binary")
    end
  end

  # ── data_read (data:read) ─────────────────────────────────────────────────

  @doc """
  Returns a curated, read-only projection of a domain resource for `plugin`.

  Enforces the plugin's `data:read` grant scoped to the requested namespace
  (deny-by-default). Only a hand-picked, non-sensitive set of fields is ever
  returned — never raw rows or secrets. `request` is `%{"resource" => ns,
  "id" => id}`.
  """
  @spec data_read(Plugin.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def data_read(%Plugin{} = plugin, %{"resource" => "media_item"} = request) do
    with :ok <- require_data_namespace(plugin, "media_item"),
         {:ok, id} <- fetch_string(request, "id"),
         {:ok, item} <- fetch_media_item(id) do
      {:ok, project_media_item(item)}
    end
  end

  def data_read(%Plugin{}, %{"resource" => other}) do
    {:error, Error.new(:invalid_request, "unknown data:read resource: #{other}")}
  end

  def data_read(%Plugin{}, _request) do
    {:error, Error.new(:invalid_request, "data:read request requires a resource")}
  end

  defp fetch_media_item(id) do
    {:ok, Media.get_media_item!(id)}
  rescue
    Ecto.NoResultsError -> {:error, Error.new(:not_found, "media_item #{id} not found")}
    Ecto.Query.CastError -> {:error, Error.new(:invalid_request, "invalid media_item id")}
  end

  # Hand-picked, non-sensitive projection. Adding a field here is a deliberate
  # decision to expose it to plugins — do not splat the struct.
  defp project_media_item(item) do
    md = item.metadata

    %{
      "id" => item.id,
      "type" => item.type,
      "title" => item.title,
      "original_title" => item.original_title,
      "year" => item.year,
      "tmdb_id" => item.tmdb_id,
      "tvdb_id" => item.tvdb_id,
      "imdb_id" => item.imdb_id,
      "overview" => md && md.overview,
      "tagline" => md && md.tagline,
      "runtime" => md && md.runtime,
      "genres" => md && md.genres,
      "poster_path" => md && md.poster_path,
      "backdrop_path" => md && md.backdrop_path,
      "rating" => md && md.vote_average
    }
  end

  # ── 1.1.0 host functions ────────────────────────────────────────────────
  #
  # Capability enforcement is final here; the post-grant body is a placeholder
  # until the owning unit implements it (U3 KV, U5 data-list, U6 ensure-watched,
  # U7 connections). Returning `:internal` keeps a premature granted call loud.

  @doc false
  @spec kv_get(Plugin.t(), String.t()) :: {:ok, term()} | {:error, Error.t()}
  def kv_get(%Plugin{} = plugin, key) do
    with :ok <- require_capability(plugin, "state:kv"),
         {:ok, key} <- validate_kv_key(key),
         {:ok, value} <- Kv.get(plugin.slug, key) do
      {:ok, to_option(value)}
    end
  end

  @doc false
  @spec kv_set(Plugin.t(), String.t(), String.t()) :: {:ok, boolean()} | {:error, Error.t()}
  def kv_set(%Plugin{} = plugin, key, value) do
    with :ok <- require_capability(plugin, "state:kv"),
         {:ok, key} <- validate_kv_key(key),
         {:ok, value} <- validate_kv_value(value),
         {:ok, _} <- Kv.set(plugin.slug, key, value) do
      {:ok, true}
    end
  end

  @doc false
  @spec kv_delete(Plugin.t(), String.t()) :: {:ok, boolean()} | {:error, Error.t()}
  def kv_delete(%Plugin{} = plugin, key) do
    with :ok <- require_capability(plugin, "state:kv"),
         {:ok, key} <- validate_kv_key(key) do
      Kv.delete(plugin.slug, key)
      {:ok, true}
    end
  end

  defp validate_kv_key(key) when is_binary(key) and key != "", do: {:ok, key}

  defp validate_kv_key(_),
    do: {:error, Error.new(:invalid_request, "kv key must be a non-empty string")}

  defp validate_kv_value(value) when is_binary(value), do: {:ok, value}

  defp validate_kv_value(_),
    do: {:error, Error.new(:invalid_request, "kv value must be a string")}

  @doc false
  @spec data_list(Plugin.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def data_list(%Plugin{} = plugin, req) do
    namespace = Map.get(req, :namespace, "")

    with :ok <- require_data_namespace(plugin, namespace),
         {:ok, cursor} <- decode_list_cursor(from_option(Map.get(req, :cursor))),
         {:ok, since} <- parse_updated_since(from_option(Map.get(req, :"updated-since"))) do
      limit = clamp_list_limit(from_option(Map.get(req, :limit)))
      list_namespace(plugin, namespace, cursor, since, limit)
    end
  end

  defp list_namespace(_plugin, "media_item", cursor, since, limit) do
    rows = Media.list_items_page(after: cursor, updated_since: since, limit: limit + 1)
    {page, next} = paginate(rows, limit)

    items =
      Enum.map(page, fn item -> {:"media-item", to_media_item(project_media_item(item))} end)

    {:ok, %{items: items, "next-cursor": next_cursor(next)}}
  end

  defp list_namespace(_plugin, "library_item", cursor, since, limit) do
    rows = Media.list_library_items_page(after: cursor, updated_since: since, limit: limit + 1)
    {page, next} = paginate(rows, limit)
    items = Enum.map(page, fn row -> {:"library-item", to_library_item(row)} end)
    {:ok, %{items: items, "next-cursor": next_cursor(next)}}
  end

  defp list_namespace(plugin, "playback_progress", cursor, since, limit) do
    # Consent-scoped (R21): only users with an active connection to this plugin
    # are visible — a non-connected user's rows are absent entirely.
    case Connections.connected_user_ids(plugin.slug) do
      [] ->
        {:ok, %{items: [], "next-cursor": :none}}

      user_ids ->
        rows =
          Playback.list_user_progress_page(user_ids,
            after: cursor,
            updated_since: since,
            limit: limit + 1
          )

        {page, next} = paginate(rows, limit)
        items = Enum.map(page, fn p -> {:"playback-progress", to_playback_progress(p)} end)
        {:ok, %{items: items, "next-cursor": next_cursor(next)}}
    end
  end

  defp list_namespace(_plugin, other, _cursor, _since, _limit) do
    {:error, Error.new(:invalid_request, "unknown data-list namespace: #{other}")}
  end

  # Fetch limit+1 to detect a next page; the cursor is the keyset of the last
  # *returned* row.
  defp paginate(rows, limit) do
    if length(rows) > limit do
      page = Enum.take(rows, limit)
      {page, List.last(page)}
    else
      {rows, nil}
    end
  end

  defp next_cursor(nil), do: :none
  defp next_cursor(%{updated_at: ts, id: id}), do: {:some, encode_list_cursor(ts, id)}

  # Opaque, request-local cursor: base64("<rfc3339>|<id>"). binary_id collation
  # differs between engines, so a cursor is valid only for the same engine within
  # a single request and is never persisted.
  defp encode_list_cursor(ts, id) do
    Base.url_encode64("#{DateTime.to_iso8601(ts)}|#{id}", padding: false)
  end

  defp decode_list_cursor(nil), do: {:ok, nil}

  defp decode_list_cursor(encoded) when is_binary(encoded) do
    with {:ok, raw} <- Base.url_decode64(encoded, padding: false),
         [iso, id] <- String.split(raw, "|", parts: 2),
         {:ok, ts, _} <- DateTime.from_iso8601(iso) do
      {:ok, {ts, id}}
    else
      _ -> {:error, Error.new(:invalid_request, "invalid data-list cursor")}
    end
  end

  defp parse_updated_since(nil), do: {:ok, nil}

  defp parse_updated_since(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, ts, _} -> {:ok, ts}
      _ -> {:error, Error.new(:invalid_request, "updated-since must be an RFC3339 timestamp")}
    end
  end

  defp clamp_list_limit(n) when is_integer(n) and n > 0, do: min(n, @data_list_page_cap)
  defp clamp_list_limit(_), do: @data_list_page_cap

  # Library row -> the WIT library-item record. Ownership is the whole point of
  # the namespace: `media-item` carries metadata but cannot answer "do we have
  # the file", which is what a sync guest needs to distinguish a catalogued item
  # from an owned one.
  defp to_library_item(row) do
    %{
      id: row.id,
      "item-type": row.type || "",
      title: row.title || "",
      year: to_option(row.year),
      "tmdb-id": to_option(row.tmdb_id),
      "tvdb-id": to_option(row.tvdb_id),
      "imdb-id": to_option(row.imdb_id),
      owned: row.owned == true,
      "updated-at": DateTime.to_iso8601(row.updated_at)
    }
  end

  # Progress row -> the WIT playback-progress record. A movie carries the item's
  # own external ids; an episode carries its coordinates plus the show's ids.
  defp to_playback_progress(p) do
    {item_type, ext, season, epnum} = progress_dimensions(p)

    %{
      "user-id": p.user_id,
      "item-type": item_type,
      "media-item-id": to_option(p.media_item_id),
      "episode-id": to_option(p.episode_id),
      "tmdb-id": to_option(ext.tmdb),
      "tvdb-id": to_option(ext.tvdb),
      "imdb-id": to_option(ext.imdb),
      "season-number": to_option(season),
      "episode-number": to_option(epnum),
      watched: p.watched == true,
      "last-watched-at": to_option(iso_or_nil(p.last_watched_at)),
      "updated-at": DateTime.to_iso8601(p.updated_at)
    }
  end

  defp progress_dimensions(%{episode_id: eid} = p) when not is_nil(eid) do
    ep = p.episode
    show = ep && ep.media_item
    {"episode", external_ids(show), ep && ep.season_number, ep && ep.episode_number}
  end

  defp progress_dimensions(p) do
    {"movie", external_ids(p.media_item), nil, nil}
  end

  defp external_ids(nil), do: %{tmdb: nil, tvdb: nil, imdb: nil}
  defp external_ids(item), do: %{tmdb: item.tmdb_id, tvdb: item.tvdb_id, imdb: item.imdb_id}

  defp iso_or_nil(nil), do: nil
  defp iso_or_nil(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  @doc false
  @spec ensure_watched(Plugin.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def ensure_watched(%Plugin{} = plugin, target) do
    with :ok <- require_surface(plugin, "playback:watched"),
         {:ok, user_id} <- fetch_target_user(target),
         :ok <- require_active_connection(plugin, user_id),
         {:ok, watched_at} <- parse_watched_at(from_option(Map.get(target, :"watched-at"))) do
      resolve_and_write(plugin, user_id, target, watched_at)
    end
  end

  @doc false
  @spec ensure_favorite(Plugin.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def ensure_favorite(%Plugin{} = plugin, _target) do
    with :ok <- require_surface(plugin, "collections:favorite") do
      {:error, Error.new(:internal, "ensure-favorite not implemented")}
    end
  end

  defp resolve_and_write(plugin, user_id, target, watched_at) do
    matcher_target = %{
      imdb: from_option(Map.get(target, :"imdb-id")),
      tmdb: from_option(Map.get(target, :"tmdb-id")),
      tvdb: from_option(Map.get(target, :"tvdb-id")),
      season: from_option(Map.get(target, :"season-number")),
      episode: from_option(Map.get(target, :"episode-number"))
    }

    case Matcher.match(matcher_target) do
      :not_found ->
        {:ok, %{status: :"not-found"}}

      {:movie, id} ->
        apply_watch(plugin, user_id, [media_item_id: id], watched_at)

      {:episode, id} ->
        apply_watch(plugin, user_id, [episode_id: id], watched_at)
    end
  end

  defp apply_watch(plugin, user_id, content_id, watched_at) do
    # Tagged plugin:<slug> so the dispatcher suppresses the echo to this plugin
    # (R14) while existing ripple (e.g. Trakt scrobble hooks) still fires.
    status =
      Playback.ensure_watched(user_id, content_id,
        origin: "plugin:#{plugin.slug}",
        watched_at: watched_at
      )

    {:ok, %{status: ensure_status(status)}}
  end

  defp ensure_status(:already_watched), do: :"already-watched"
  defp ensure_status(:changed), do: :changed

  defp fetch_target_user(target) do
    case Map.get(target, :"user-id") do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, Error.new(:invalid_request, "ensure-watched requires a user-id")}
    end
  end

  # Consent boundary (R21): a plugin may only write for a user who has an active
  # connection to it.
  defp require_active_connection(plugin, user_id) do
    if Connections.active?(plugin.slug, user_id) do
      :ok
    else
      {:error,
       Error.new(:capability_denied, "user #{user_id} has no active connection to #{plugin.slug}")}
    end
  end

  defp parse_watched_at(nil), do: {:ok, nil}

  defp parse_watched_at(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, ts, _} -> {:ok, DateTime.truncate(ts, :second)}
      _ -> {:error, Error.new(:invalid_request, "watched-at must be an RFC3339 timestamp")}
    end
  end

  @doc false
  @spec connections_list(Plugin.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def connections_list(%Plugin{} = plugin) do
    with :ok <- require_capability(plugin, "users:connections") do
      records =
        plugin.slug
        |> Connections.list_for_plugin()
        |> Enum.map(&to_connection_record/1)

      {:ok, records}
    end
  end

  # Identity + status ONLY — the WIT `connection` record has no token field, so
  # the token cannot cross the boundary by construction (R22).
  defp to_connection_record(conn) do
    %{
      id: conn.id,
      "user-id": conn.user_id,
      "external-user-id": to_option(conn.external_user_id),
      "external-username": to_option(conn.external_username),
      status: connection_status_atom(conn.status)
    }
  end

  defp connection_status_atom("error"), do: :error
  defp connection_status_atom(_), do: :connected

  @doc false
  @spec connection_request(Plugin.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def connection_request(%Plugin{} = plugin, connection_id, request, opts) do
    with :ok <- require_capability(plugin, "net:http"),
         :ok <- require_capability(plugin, "users:connections"),
         {:ok, conn} <- fetch_connection(plugin, connection_id),
         {:ok, url} <- fetch_string(request, "url") do
      # Strip any guest-supplied Authorization and inject the bearer token the
      # host holds (R22) — the guest never sees the token.
      headers =
        request
        |> Map.get("headers", %{})
        |> strip_authorization()
        |> Map.put("authorization", "Bearer #{conn.access_token}")

      gate_opts =
        [
          allowed_hosts: Plugin.granted_http_hosts(plugin),
          slug: plugin.slug,
          method: Map.get(request, "method", "GET"),
          headers: headers,
          body: Map.get(request, "body")
        ] ++ Keyword.take(opts, [:allow_private, :resolver, :max_bytes, :timeout])

      case Gate.request(url, gate_opts) do
        {:ok, resp} -> {:ok, http_response_map(resp)}
        {:error, _} = err -> err
      end
    end
  end

  defp fetch_connection(plugin, connection_id) when is_binary(connection_id) do
    case Connections.get_by_id(plugin.slug, connection_id) do
      %{} = conn ->
        {:ok, conn}

      nil ->
        {:error,
         Error.new(:not_found, "connection #{connection_id} not found for #{plugin.slug}")}
    end
  end

  defp fetch_connection(_plugin, _),
    do: {:error, Error.new(:invalid_request, "connection-id must be a string")}

  defp strip_authorization(headers) when is_map(headers) do
    Enum.reject(headers, fn {k, _v} -> String.downcase(to_string(k)) == "authorization" end)
    |> Map.new()
  end

  # ── Capability checks (deny-by-default) ───────────────────────────────────

  defp require_capability(plugin, class) do
    if Plugin.granted?(plugin, class) do
      :ok
    else
      {:error, denial(plugin, "capability #{class}", Map.has_key?(plugin.capabilities, class))}
    end
  end

  defp require_data_namespace(plugin, namespace) do
    require_scoped(plugin, "data:read", namespace, "data:read namespace #{namespace}")
  end

  # surfaces:write is scoped to a value vocabulary (e.g. "playback:watched"),
  # like data:read namespaces — a plain class grant is not enough.
  defp require_surface(plugin, surface) do
    require_scoped(plugin, "surfaces:write", surface, "surfaces:write #{surface}")
  end

  defp require_scoped(plugin, class, value, label) do
    if value in List.wrap(Map.get(plugin.granted_capabilities, class)) do
      :ok
    else
      {:error, denial(plugin, label, value in List.wrap(Map.get(plugin.capabilities, class)))}
    end
  end

  # A denial where the plugin's own manifest declares what it asked for is a
  # stale grant — the manifest was revised after approval and the operator has
  # not re-approved — not a plugin asking for something it never declared. Saying
  # so makes the message the guest, the dispatcher log, and the activity log all
  # see actionable instead of a bare "not granted".
  defp denial(plugin, what, declared?) do
    if declared? do
      Error.new(
        :capability_denied,
        "#{what} is requested by #{plugin.slug} but was never granted — re-approve the " <>
          "plugin under Configuration > Plugins to grant its current capabilities"
      )
    else
      Error.new(:capability_denied, "#{what} not granted to #{plugin.slug}")
    end
  end

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, Error.new(:invalid_request, "missing or invalid #{key}")}
    end
  end
end
