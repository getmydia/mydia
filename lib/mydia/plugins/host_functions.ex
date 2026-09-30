defmodule Mydia.Plugins.HostFunctions do
  @moduledoc """
  Typed WIT host imports exposed to component guests (U4).

  Host functions are the plugin platform's capability model: a guest can only
  affect the outside world by calling an imported host function, and each one
  enforces the plugin's **server-side** grant (deny-by-default) before doing any
  work. Grants are resolved from the runtime registry on *every* call, so a
  revoked capability takes effect immediately (a plugin can never widen its own
  grant — KTD6).

  ## Component import ABI (1.4)

  Imports live under the `"mydia:plugin/host@1.4.0"` interface namespace and
  receive/return **typed WIT records** — no linear-memory marshalling. Wasmex
  hands each import closure the decoded record (atom-keyed map; `option<T>` as
  `{:some, v}` / `:none`; `list<tuple>` as `[{k, v}]`) and marshals the closure's
  return value back across the boundary. The 1.0 functions —

    * `http-request(outbound-request) -> result<outbound-response, host-error>`
    * `data-read(data-request) -> result<read-result, host-error>`
    * `log(string, string)` — ungated, fire-and-forget

  are joined in 1.1 by `kv-get/set/delete`, `data-list`, `ensure-watched`,
  `connections-list`, and `connection-request` (each capability-gated), and in
  1.2 by `set-watch-state` plus position fields on `playback-progress`, in
  1.3 by `ensure-favorite`, and in 1.4 by `links-list`, `link-request`,
  `propose-accounts`, `set-link-token`, `set-link-status`, `kv-list`,
  `kv-set-many` and `report-sync-run`, plus `origin` on `playback-progress`.

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

  alias Mydia.Accounts
  alias Mydia.Accounts.Scope
  alias Mydia.Collections
  alias Mydia.Media
  alias Mydia.Playback
  alias Mydia.Plugins
  alias Mydia.Plugins.AccountLink
  alias Mydia.Plugins.AccountLinks
  alias Mydia.Plugins.Endpoints
  alias Mydia.Plugins.Connections
  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Instance
  alias Mydia.Plugins.Instances
  alias Mydia.Plugins.Kv
  alias Mydia.Plugins.Logs
  alias Mydia.Plugins.Manifest
  alias Mydia.Plugins.Matcher
  alias Mydia.Plugins.Net.Gate
  alias Mydia.Plugins.Plugin

  # Hard page cap for data-list — a guest may request fewer but never more.
  @data_list_page_cap 200

  # The WIT host interface namespace. The version suffix is the ABI version.
  # wasmtime serves this 1.4 superset to a 1.3/1.2/1.1/1.0 guest (which imports
  # the correspondingly older `host@x.y.z`) via component semver matching, so
  # older guests keep working. wasmex still needs exact namespace keys in the
  # imports map (see `Mydia.Plugins.Host`), so every supported version is also
  # published under its own key, each narrowed to the functions that version
  # defined.
  @namespace "mydia:plugin/host@1.4.0"
  @v13_namespace "mydia:plugin/host@1.3.0"
  @v12_namespace "mydia:plugin/host@1.2.0"
  @v11_namespace "mydia:plugin/host@1.1.0"

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
      v13 = %{
        "http-request" => {:fn, http_import(slug, ctx, gate_opts)},
        "data-read" => {:fn, data_import(slug)},
        "log" => {:fn, log_import(slug, ctx)},
        # ── 1.1.0 ──
        "kv-get" => {:fn, kv_get_import(slug)},
        "kv-set" => {:fn, kv_set_import(slug)},
        "kv-delete" => {:fn, kv_delete_import(slug)},
        "data-list" => {:fn, data_list_import(slug, false)},
        "ensure-watched" => {:fn, ensure_watched_import(slug)},
        "connections-list" => {:fn, connections_list_import(slug, ctx)},
        "connection-request" => {:fn, connection_request_import(slug, ctx, gate_opts)},
        # ── 1.2.0 ──
        "set-watch-state" => {:fn, set_watch_state_import(slug)},
        # ── 1.3.0 ──
        "ensure-favorite" => {:fn, ensure_favorite_import(slug)}
      }

      v14 =
        Map.merge(v13, %{
          # 1.4 playback-progress records carry `origin`; older guests' records
          # must not, or the record shape no longer matches their contract.
          "data-list" => {:fn, data_list_import(slug, true)},
          "links-list" => {:fn, links_list_import(slug, ctx)},
          "link-request" => {:fn, link_request_import(slug, ctx, gate_opts)},
          "propose-accounts" => {:fn, propose_accounts_import(slug, ctx)},
          "set-link-token" => {:fn, set_link_token_import(slug, ctx)},
          "set-link-status" => {:fn, set_link_status_import(slug, ctx)},
          "kv-list" => {:fn, not_implemented(2)},
          "kv-set-many" => {:fn, not_implemented(1)},
          "report-sync-run" => {:fn, not_implemented(1)}
        })

      # Publish under every supported key: wasmex matches the guest's exact
      # imported package name, so an older guest still links against this host.
      # Each older key is narrowed to what that version actually declared, or
      # the guest would import a function its own contract never defined.
      %{
        @namespace => v14,
        @v13_namespace => v13,
        @v12_namespace => Map.delete(v13, "ensure-favorite"),
        @v11_namespace => v13 |> Map.delete("ensure-favorite") |> Map.delete("set-watch-state")
      }
    end
  end

  # 1.4 imports are linked from Task 1 so a 1.4 guest instantiates; each body is
  # replaced by the task that owns it (links: Task 5, store: Task 7, sync runs:
  # Task 8). Until then a call returns an internal error.
  defp not_implemented(0), do: fn -> {:error, {:internal, "not implemented"}} end
  defp not_implemented(1), do: fn _ -> {:error, {:internal, "not implemented"}} end
  defp not_implemented(2), do: fn _, _ -> {:error, {:internal, "not implemented"}} end
  defp not_implemented(3), do: fn _, _, _ -> {:error, {:internal, "not implemented"}} end

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

  defp data_list_import(slug, with_origin?) do
    fn req ->
      typed_result(fn ->
        with {:ok, plugin} <- Plugins.get_plugin(slug) do
          data_list(plugin, req, with_origin: with_origin?)
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

  defp set_watch_state_import(slug) do
    fn target ->
      typed_result(fn ->
        with {:ok, plugin} <- Plugins.get_plugin(slug) do
          set_watch_state(plugin, target)
        end
      end)
    end
  end

  defp connections_list_import(slug, ctx) do
    fn ->
      typed_result(fn ->
        with {:ok, plugin} <- Plugins.get_plugin(slug) do
          connections_list(plugin, ctx_instance(ctx) || Instances.default_instance(slug))
        end
      end)
    end
  end

  defp connection_request_import(slug, ctx, gate_opts) do
    fn connection_id, req ->
      typed_result(fn ->
        with {:ok, plugin} <- Plugins.get_plugin(slug),
             {:ok, resp} <-
               connection_request(
                 plugin,
                 connection_id,
                 from_outbound_request(req),
                 [instance: ctx_instance(ctx)] ++ gate_opts
               ) do
          {:ok, to_outbound_response(resp)}
        end
      end)
    end
  end

  defp links_list_import(slug, ctx) do
    fn ->
      typed_result(fn ->
        with {:ok, plugin, instance} <- plugin_and_instance(slug, ctx) do
          links_list(plugin, instance)
        end
      end)
    end
  end

  defp link_request_import(slug, ctx, gate_opts) do
    fn link_id, req ->
      typed_result(fn ->
        with {:ok, plugin, instance} <- plugin_and_instance(slug, ctx),
             {:ok, resp} <-
               link_request(plugin, instance, link_id, from_outbound_request(req), gate_opts) do
          {:ok, to_outbound_response(resp)}
        end
      end)
    end
  end

  defp propose_accounts_import(slug, ctx) do
    fn accounts ->
      typed_result(fn ->
        with {:ok, plugin, instance} <- plugin_and_instance(slug, ctx) do
          propose_accounts(plugin, instance, accounts)
        end
      end)
    end
  end

  defp set_link_token_import(slug, ctx) do
    fn link_id, token ->
      typed_result(fn ->
        with {:ok, plugin, instance} <- plugin_and_instance(slug, ctx) do
          set_link_token(plugin, instance, link_id, token)
        end
      end)
    end
  end

  defp set_link_status_import(slug, ctx) do
    fn link_id, status, message ->
      typed_result(fn ->
        with {:ok, plugin, instance} <- plugin_and_instance(slug, ctx) do
          set_link_status(plugin, instance, link_id, status, message)
        end
      end)
    end
  end

  # The instance this invocation runs for (Task 4 puts its id in ctx). Tests and
  # the admin Test button may run without one.
  defp ctx_instance(%{instance_id: id}) when is_binary(id), do: Instances.get(id)
  defp ctx_instance(_ctx), do: nil

  # 1.4 imports are instance-scoped by definition: without an instance there is
  # nothing to act on.
  defp plugin_and_instance(slug, ctx) do
    with {:ok, plugin} <- Plugins.get_plugin(slug) do
      case ctx_instance(ctx) do
        nil -> {:error, Error.new(:not_found, "no plugin instance for this invocation")}
        instance -> {:ok, plugin, instance}
      end
    end
  end

  # ── http-request import ────────────────────────────────────────────────────

  defp http_import(slug, ctx, gate_opts) do
    fn req ->
      typed_result(fn ->
        with {:ok, plugin} <- Plugins.get_plugin(slug),
             {:ok, resp} <-
               http_request(
                 plugin,
                 from_outbound_request(req),
                 [instance: ctx_instance(ctx)] ++ gate_opts
               ) do
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
      :ok -> :ok
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
  # Direct unit-test callers pass bare values; WIT marshalling uses option tuples.
  defp from_option(value), do: value

  # ── http_request (net:http) ───────────────────────────────────────────────

  @doc """
  Performs a gated outbound HTTP request on behalf of `plugin`.

  Enforces the plugin's `net:http` grant (deny-by-default) and routes through
  `Mydia.Plugins.Net.Gate`. `request` is the string-key map adapted from the WIT
  `outbound-request`: `%{"url" => url, "method" => "POST", "headers" => %{},
  "body" => "..."}`.

  `opts` are host-side only (e.g. the `:allow_private` test seam) — never derived
  from the guest request. `:instance` is the invoking `%Instance{}`; its approved
  endpoints join the gate options.
  """
  @spec http_request(Plugin.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def http_request(%Plugin{} = plugin, request, opts \\ []) do
    with :ok <- require_capability(plugin, "net:http"),
         {:ok, url} <- fetch_string(request, "url"),
         :ok <- require_granted_host(plugin, url) do
      gate_opts =
        Endpoints.gate_opts(plugin, Keyword.get(opts, :instance)) ++
          [
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
    {:ok, Media.get_media_item!(Scope.system(), id)}
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
  @spec data_list(Plugin.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def data_list(%Plugin{} = plugin, req, opts \\ []) do
    namespace = Map.get(req, :namespace, "")

    with :ok <- require_data_namespace(plugin, namespace),
         {:ok, cursor} <- decode_list_cursor(from_option(Map.get(req, :cursor))),
         {:ok, since} <- parse_updated_since(from_option(Map.get(req, :"updated-since"))) do
      limit = clamp_list_limit(from_option(Map.get(req, :limit)))
      list_namespace(plugin, namespace, cursor, since, limit, opts)
    end
  end

  defp list_namespace(_plugin, "media_item", cursor, since, limit, _opts) do
    rows =
      Media.list_items_page(Scope.system(), after: cursor, updated_since: since, limit: limit + 1)

    {page, next} = paginate(rows, limit)

    items =
      Enum.map(page, fn item -> {:"media-item", to_media_item(project_media_item(item))} end)

    {:ok, %{items: items, "next-cursor": next_cursor(next)}}
  end

  defp list_namespace(_plugin, "library_item", cursor, since, limit, _opts) do
    rows =
      Media.list_library_items_page(Scope.system(),
        after: cursor,
        updated_since: since,
        limit: limit + 1
      )

    {page, next} = paginate(rows, limit)
    items = Enum.map(page, fn row -> {:"library-item", to_library_item(row)} end)
    {:ok, %{items: items, "next-cursor": next_cursor(next)}}
  end

  defp list_namespace(plugin, "playback_progress", cursor, since, limit, opts) do
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
        with_origin? = Keyword.get(opts, :with_origin, false)

        items =
          Enum.map(page, fn p ->
            {:"playback-progress", to_playback_progress(p, with_origin?)}
          end)

        {:ok, %{items: items, "next-cursor": next_cursor(next)}}
    end
  end

  defp list_namespace(_plugin, other, _cursor, _since, _limit, _opts) do
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
  defp to_playback_progress(p, with_origin?) do
    {item_type, ext, season, epnum} = progress_dimensions(p)

    record = %{
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
      "position-seconds": to_option(p.position_seconds),
      "duration-seconds": to_option(p.duration_seconds),
      "last-watched-at": to_option(iso_or_nil(p.last_watched_at)),
      "updated-at": DateTime.to_iso8601(p.updated_at)
    }

    # Task 8 replaces :none with the row's real origin.
    if with_origin?, do: Map.put(record, :origin, :none), else: record
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
  def ensure_favorite(%Plugin{} = plugin, target) do
    with :ok <- require_surface(plugin, "collections:favorite"),
         {:ok, user_id} <- fetch_favorite_user(target),
         :ok <- require_active_connection(plugin, user_id) do
      resolve_and_favorite(user_id, target)
    end
  end

  defp resolve_and_favorite(user_id, target) do
    matcher_target = %{
      imdb: from_option(Map.get(target, :"imdb-id")),
      tmdb: from_option(Map.get(target, :"tmdb-id")),
      tvdb: from_option(Map.get(target, :"tvdb-id"))
    }

    case Matcher.match_item(matcher_target) do
      :not_found -> {:ok, %{status: :"not-found"}}
      {:media_item, id} -> apply_favorite(user_id, id)
    end
  end

  # Additive by contract: a remote list can add to a user's Favorites but never
  # remove from it, so a service-side deletion can never destroy local curation.
  defp apply_favorite(user_id, media_item_id) do
    user = Accounts.get_user!(user_id)

    if Collections.is_favorite?(Scope.for_user(user), media_item_id) do
      {:ok, %{status: :"already-favorited"}}
    else
      with {:ok, favorites} <- Collections.get_or_create_favorites(user),
           {:ok, _item} <- Collections.add_item(favorites, media_item_id) do
        {:ok, %{status: :changed}}
      else
        # The check above is not atomic with the insert. A concurrent favorite
        # (the user tapping the star while a sync tick runs) trips the
        # `collection_items` unique index, which is the same outcome the check
        # guards against, so report it as such rather than as a host failure.
        {:error, %Ecto.Changeset{errors: errors}} ->
          if Keyword.has_key?(errors, :collection_id) or Keyword.has_key?(errors, :media_item_id) do
            {:ok, %{status: :"already-favorited"}}
          else
            {:error, Error.new(:internal, "could not add favorite")}
          end

        _ ->
          {:error, Error.new(:internal, "could not add favorite")}
      end
    end
  end

  defp fetch_favorite_user(target) do
    case Map.get(target, :"user-id") do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, Error.new(:invalid_request, "ensure-favorite requires a user-id")}
    end
  end

  @doc false
  @spec set_watch_state(Plugin.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def set_watch_state(%Plugin{} = plugin, target) do
    with :ok <- require_surface(plugin, "playback:watched"),
         {:ok, user_id} <- fetch_target_user(target),
         :ok <- require_active_connection(plugin, user_id),
         {:ok, watched_at} <- parse_watched_at(from_option(Map.get(target, :"watched-at"))) do
      resolve_and_set_state(plugin, user_id, target, watched_at)
    end
  end

  defp resolve_and_write(plugin, user_id, target, watched_at) do
    matcher_target = matcher_target(target)

    case Matcher.match(matcher_target) do
      :not_found ->
        {:ok, %{status: :"not-found"}}

      {:movie, id} ->
        apply_watch(plugin, user_id, [media_item_id: id], watched_at)

      {:episode, id} ->
        apply_watch(plugin, user_id, [episode_id: id], watched_at)
    end
  end

  defp resolve_and_set_state(plugin, user_id, target, watched_at) do
    matcher_target = matcher_target(target)

    case Matcher.match(matcher_target) do
      :not_found ->
        {:ok, %{status: :"not-found"}}

      {:movie, id} ->
        apply_watch_state(plugin, user_id, [media_item_id: id], target, watched_at)

      {:episode, id} ->
        apply_watch_state(plugin, user_id, [episode_id: id], target, watched_at)
    end
  end

  defp matcher_target(target) do
    %{
      imdb: from_option(Map.get(target, :"imdb-id")),
      tmdb: from_option(Map.get(target, :"tmdb-id")),
      tvdb: from_option(Map.get(target, :"tvdb-id")),
      season: from_option(Map.get(target, :"season-number")),
      episode: from_option(Map.get(target, :"episode-number"))
    }
  end

  defp apply_watch(plugin, user_id, content_id, watched_at) do
    # Tagged plugin:<slug> so the dispatcher suppresses the echo to this plugin
    # (R14) while existing ripple (e.g. media-server watched sync) still fires.
    status =
      Playback.ensure_watched(user_id, content_id,
        origin: "plugin:#{plugin.slug}",
        watched_at: watched_at
      )

    {:ok, %{status: ensure_status(status)}}
  end

  defp apply_watch_state(plugin, user_id, content_id, target, watched_at) do
    origin = "plugin:#{plugin.slug}"
    position = from_option(Map.get(target, :"position-seconds"))
    duration = from_option(Map.get(target, :"duration-seconds"))
    watched = Map.get(target, :watched) == true

    cond do
      # A present resume position is authoritative: write it (and the watched
      # flag) without the 90% auto-mark flipping an in-progress scrub to watched.
      not is_nil(position) ->
        attrs = %{
          position_seconds: position,
          duration_seconds: duration,
          watched: watched
        }

        attrs =
          if watched_at, do: Map.put(attrs, :last_watched_at, watched_at), else: attrs

        case Playback.save_progress(user_id, content_id, attrs,
               origin: origin,
               authoritative_watched: true
             ) do
          {:ok, _} -> {:ok, %{status: :changed}}
          {:error, _} -> {:error, Error.new(:internal, "set-watch-state failed to save progress")}
        end

      watched ->
        apply_watch(plugin, user_id, content_id, watched_at)

      true ->
        case Playback.delete_progress(user_id, content_id, origin: origin) do
          {:ok, _} -> {:ok, %{status: :changed}}
          {:error, :not_found} -> {:ok, %{status: :"already-watched"}}
        end
    end
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
  # 1.1-1.3 connections-list: the instance's *user* links in the old record shape.
  @spec connections_list(Plugin.t(), Instance.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def connections_list(%Plugin{} = plugin, %Instance{} = instance) do
    with :ok <- require_capability(plugin, "users:connections") do
      records =
        instance.id
        |> AccountLinks.list()
        # Only user links are connections, and the guest enum has just
        # connected|error, so a disabled link is not listed at all.
        |> Enum.filter(&(&1.role == :user and &1.status != :disabled))
        |> Enum.map(&to_connection_record/1)

      {:ok, records}
    end
  end

  # Identity + status ONLY: the WIT `connection` record has no token field, so
  # the token cannot cross the boundary by construction.
  defp to_connection_record(%AccountLink{} = link) do
    %{
      id: link.id,
      "user-id": link.user_id,
      "external-user-id": to_option(link.external_user_id),
      "external-username": to_option(link.external_username),
      status: if(link.status == :active, do: :connected, else: :error)
    }
  end

  @doc false
  @spec links_list(Plugin.t(), Instance.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def links_list(%Plugin{} = plugin, %Instance{} = instance) do
    with :ok <- require_capability(plugin, "users:connections") do
      {:ok, instance.id |> AccountLinks.list() |> Enum.map(&to_link_record/1)}
    end
  end

  # Identity + status ONLY, never the token (same rule as the 1.1 record).
  defp to_link_record(%AccountLink{} = link) do
    %{
      id: link.id,
      role: link.role,
      "user-id": to_option(link.user_id),
      "external-user-id": to_option(link.external_user_id),
      "external-username": to_option(link.external_username),
      status: link.status
    }
  end

  @doc false
  # Serves 1.4 link-request and, through connection_request/4, 1.1-1.3
  # connection-request. Any role may be used; the link must belong to the
  # calling instance, not be disabled, and hold a token. The manifest's
  # auth_header template names the header; any guest header with that name
  # (case-insensitive) is stripped before the host's is added.
  @spec link_request(Plugin.t(), Instance.t(), term(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def link_request(%Plugin{} = plugin, %Instance{} = instance, link_id, request, opts \\ []) do
    with :ok <- require_capability(plugin, "net:http"),
         :ok <- require_capability(plugin, "users:connections"),
         {:ok, link} <- fetch_link(plugin, instance, link_id, Keyword.get(opts, :roles)),
         :ok <- require_usable(link),
         {:ok, url} <- fetch_string(request, "url") do
      {header, template} = Manifest.auth_header(plugin.connection)
      name = String.downcase(header)

      headers =
        request
        |> Map.get("headers", %{})
        |> Enum.reject(fn {k, _v} -> String.downcase(to_string(k)) == name end)
        |> Map.new()
        |> Map.put(name, String.replace(template, "{token}", link.access_token))

      gate_opts =
        Endpoints.gate_opts(plugin, instance) ++
          [
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

  @doc false
  # The 1.1 entry point: a connection is a user link. `opts[:instance]` is the
  # invocation's instance; without one, the plugin's default instance. Owner and
  # endpoint credentials are not connections: a 1.1-1.3 guest can never use them.
  @spec connection_request(Plugin.t(), term(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def connection_request(%Plugin{} = plugin, connection_id, request, opts) do
    instance = Keyword.get(opts, :instance) || Instances.default_instance(plugin.slug)
    link_request(plugin, instance, connection_id, request, Keyword.put(opts, :roles, [:user]))
  end

  @max_proposed_accounts 500

  @doc false
  @spec propose_accounts(Plugin.t(), Instance.t(), term()) :: :ok | {:error, Error.t()}
  def propose_accounts(%Plugin{} = plugin, %Instance{} = instance, accounts) do
    with :ok <- require_capability(plugin, "users:connections"),
         {:ok, rows} <- validate_accounts(accounts),
         {:ok, _} <- Instances.set_remote_accounts(instance, rows) do
      :ok
    end
  end

  defp validate_accounts(accounts)
       when is_list(accounts) and length(accounts) <= @max_proposed_accounts do
    accounts
    |> Enum.reduce_while({:ok, []}, fn account, {:ok, acc} ->
      id = Map.get(account, :id)
      name = Map.get(account, :name)

      if is_binary(id) and id != "" and is_binary(name) do
        row = %{id: id, name: String.slice(name, 0, 200), admin: Map.get(account, :admin) == true}
        {:cont, {:ok, [row | acc]}}
      else
        {:halt,
         {:error, Error.new(:invalid_request, "remote-account needs a non-empty id and a name")}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      err -> err
    end
  end

  defp validate_accounts(_) do
    {:error,
     Error.new(
       :invalid_request,
       "propose-accounts takes at most #{@max_proposed_accounts} accounts"
     )}
  end

  @doc false
  @spec set_link_token(Plugin.t(), Instance.t(), term(), term()) :: :ok | {:error, Error.t()}
  def set_link_token(%Plugin{} = plugin, %Instance{} = instance, link_id, token) do
    with :ok <- require_capability(plugin, "users:connections"),
         {:ok, link} <- fetch_link(plugin, instance, link_id),
         :ok <- reject_disabled(link),
         {:ok, token} <- validate_token(token) do
      AccountLinks.set_token(link.id, token)
    end
  end

  # :disabled is the host's kill switch; a guest can neither revive nor edit it.
  defp reject_disabled(%AccountLink{status: :disabled}),
    do: {:error, Error.new(:capability_denied, "link is disabled")}

  defp reject_disabled(%AccountLink{}), do: :ok

  # The token is later interpolated into a header value, so control characters
  # (CR, LF, NUL and the rest of C0/DEL) are refused.
  defp validate_token(token)
       when is_binary(token) and token != "" and byte_size(token) <= 4096 do
    if String.match?(token, ~r/[\x00-\x1f\x7f]/) do
      {:error, Error.new(:invalid_request, "token must not contain control characters")}
    else
      {:ok, token}
    end
  end

  defp validate_token(_) do
    {:error,
     Error.new(:invalid_request, "token must be a non-empty string of at most 4096 bytes")}
  end

  @doc false
  @spec set_link_status(Plugin.t(), Instance.t(), term(), term(), term()) ::
          :ok | {:error, Error.t()}
  def set_link_status(%Plugin{} = plugin, %Instance{} = instance, link_id, status, message) do
    with :ok <- require_capability(plugin, "users:connections"),
         {:ok, link} <- fetch_link(plugin, instance, link_id),
         :ok <- reject_disabled(link),
         {:ok, status} <- link_status(status) do
      AccountLinks.set_status(link.id, status, from_option(message))
    end
  end

  @link_statuses %{"active" => :active, "error" => :error, "disabled" => :disabled}

  defp link_status(status) when is_atom(status) or is_binary(status) do
    case Map.fetch(@link_statuses, to_string(status)) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, Error.new(:invalid_request, "unknown link-status #{inspect(status)}")}
    end
  end

  defp link_status(other),
    do: {:error, Error.new(:invalid_request, "unknown link-status #{inspect(other)}")}

  defp fetch_link(plugin, %Instance{} = instance, link_id, roles \\ nil) do
    link = AccountLinks.get_in_instance(instance.id, link_id)

    if match?(%AccountLink{}, link) and (is_nil(roles) or link.role in roles) do
      {:ok, link}
    else
      {:error, Error.new(:not_found, "link #{inspect(link_id)} not found for #{plugin.slug}")}
    end
  end

  defp require_usable(%AccountLink{status: :disabled}),
    do: {:error, Error.new(:capability_denied, "link is disabled")}

  defp require_usable(%AccountLink{access_token: token}) when token in [nil, ""],
    do: {:error, Error.new(:capability_denied, "link has no token yet")}

  defp require_usable(%AccountLink{}), do: :ok

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
