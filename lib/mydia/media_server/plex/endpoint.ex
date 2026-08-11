defmodule Mydia.MediaServer.Plex.Endpoint do
  @moduledoc """
  Resolves a working Plex base URL at call time.

  A Plex server advertises several addresses and any of them can stop working
  when it moves networks. Storing one frozen address (the previous behaviour)
  produced a config that timed out for months with no way to recover. This
  module probes every candidate concurrently, caches the winner, and drops the
  cache when it stops working.
  """

  alias Mydia.MediaServer.Error
  alias Mydia.MediaServer.PlexOAuth
  alias Mydia.Settings
  alias Mydia.Settings.MediaServerConfig

  @table :plex_endpoint_cache
  @probe_path "/library/sections"
  @probe_timeout_ms 3_000
  @cache_ttl_ms :timer.minutes(10)

  @doc """
  Returns a working base URL for the config.

  An explicit `url` on the config is a manual operator override and wins over
  discovery. Otherwise the cached winner is reused when fresh, and failing that
  every candidate is probed concurrently.
  """
  @spec resolve(MediaServerConfig.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def resolve(%MediaServerConfig{url: url} = config) when is_binary(url) and url != "" do
    case probe(url, config.token) do
      :ok -> {:ok, url}
      {:error, _} = err -> err
    end
  end

  def resolve(%MediaServerConfig{} = config) do
    case cached(config) do
      {:ok, url} -> {:ok, url}
      :miss -> probe_all(config)
    end
  end

  @doc """
  Re-fetches the server's advertised addresses from plex.tv and persists them.

  Matches on `machine_identifier` rather than name or address, because the name
  is editable and every address can change at once. This is the "my Plex server
  moved" recovery path and requires no operator action.

  Options:
    * `:plex_tv_base` - override the plex.tv base URL (tests only)
  """
  @spec rediscover(MediaServerConfig.t(), keyword()) ::
          {:ok, MediaServerConfig.t()} | {:error, Error.t()}
  # Multiple clauses with a default argument require an explicit function head.
  def rediscover(config, opts \\ [])

  def rediscover(%MediaServerConfig{machine_identifier: nil}, _opts),
    do: {:error, Error.unexpected("no machine_identifier recorded; reconnect this server")}

  def rediscover(%MediaServerConfig{} = config, opts) do
    with {:ok, servers} <- PlexOAuth.list_servers(config.token, opts),
         %{} = match <- find_by_identifier(servers, config.machine_identifier),
         {:ok, updated} <- persist(config, match) do
      invalidate(config)
      {:ok, updated}
    else
      nil ->
        {:error, Error.unexpected("server #{config.machine_identifier} not on this account")}

      {:error, %Error{}} = err ->
        err

      {:error, reason} ->
        {:error, Error.unexpected(inspect(reason))}
    end
  end

  @doc "Drops the cached winner so the next resolve re-probes."
  @spec invalidate(MediaServerConfig.t()) :: :ok
  def invalidate(%MediaServerConfig{id: id}) do
    ensure_table()
    :ets.delete(@table, id)
    :ok
  end

  @doc false
  @spec invalidate_all() :: :ok
  def invalidate_all do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  # ── Private ────────────────────────────────────────────────────────

  defp probe_all(config), do: probe_all(config, false)

  defp probe_all(%MediaServerConfig{connections: connections, token: token} = config, retried?) do
    uris = connections |> Enum.map(&candidate_uri/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    # `ordered: false` plus a lazy scan lets the first working candidate win
    # immediately. Materialising every result first would make resolution wait
    # for the slowest dead address even when a good one answered at once, which
    # is the latency this whole module exists to remove.
    stream =
      Task.async_stream(uris, fn uri -> {uri, probe(uri, token)} end,
        timeout: @probe_timeout_ms + 1_000,
        on_timeout: :kill_task,
        ordered: false,
        max_concurrency: max(length(uris), 1)
      )
      |> Stream.flat_map(fn
        {:ok, result} -> [result]
        {:exit, _} -> []
      end)

    {winner, results} = first_success(stream)

    case winner do
      {uri, :ok} ->
        put_cache(config, uri)
        {:ok, uri}

      nil ->
        error = worst_error(results)

        if not retried? and error.kind == :unreachable and
             is_binary(config.machine_identifier) do
          case rediscover(config) do
            {:ok, updated} -> probe_all(updated, true)
            {:error, _} -> {:error, error}
          end
        else
          {:error, error}
        end
    end
  end

  # Walks the stream only as far as the first success. Returns that result (or
  # nil) plus everything consumed, so error classification still sees the
  # failures observed along the way.
  defp first_success(stream) do
    Enum.reduce_while(stream, {nil, []}, fn
      {_uri, :ok} = hit, {_, seen} -> {:halt, {hit, [hit | seen]}}
      other, {_, seen} -> {:cont, {nil, [other | seen]}}
    end)
    |> then(fn {hit, seen} -> {hit, Enum.reverse(seen)} end)
  end

  # An auth failure is more informative than a timeout: it means we reached a
  # Plex server and it rejected us, so rediscovery would not help.
  defp worst_error([]), do: Error.unreachable("no connection candidates configured")

  defp worst_error(results) do
    errors = for {_uri, {:error, e}} <- results, do: e

    Enum.find(errors, &(&1.kind == :auth)) ||
      Enum.find(errors, &(&1.kind == :unexpected)) ||
      List.first(errors) ||
      Error.unreachable("all candidates failed")
  end

  defp find_by_identifier(servers, identifier) do
    Enum.find(servers, &(&1.machine_identifier == identifier))
  end

  defp persist(config, server) do
    Settings.update_media_server_config(config, %{
      connections: connections_for_storage(server.connections),
      server_access_token: server.access_token
    })
  end

  # parse_server/1 yields atom-keyed connection maps for LiveView; storage and
  # reload use string keys via Jason, so persist the same shape the DB returns.
  defp connections_for_storage(connections) do
    Enum.map(connections, fn
      %{uri: _} = conn ->
        %{
          "uri" => conn.uri,
          "protocol" => conn.protocol,
          "address" => conn.address,
          "port" => conn.port,
          "local" => conn.local,
          "relay" => conn.relay
        }

      %{"uri" => _} = conn ->
        conn

      other ->
        other
    end)
  end

  defp candidate_uri(%{"uri" => uri}) when is_binary(uri), do: uri
  defp candidate_uri(%{uri: uri}) when is_binary(uri), do: uri
  defp candidate_uri(_), do: nil

  defp probe(uri, token) do
    (String.trim_trailing(uri, "/") <> @probe_path)
    |> Req.get(
      headers: [{"X-Plex-Token", token || ""}, {"Accept", "application/json"}],
      retry: false,
      receive_timeout: @probe_timeout_ms,
      connect_options: [timeout: @probe_timeout_ms]
    )
    |> classify()
  end

  defp classify({:ok, %{status: s}}) when s in 200..299, do: :ok
  defp classify({:ok, %{status: s}}) when s in [401, 403], do: {:error, Error.auth("HTTP #{s}")}
  defp classify({:ok, %{status: s}}), do: {:error, Error.unexpected("HTTP #{s}")}

  defp classify({:error, %Req.TransportError{} = e}),
    do: {:error, Error.unreachable(Exception.message(e))}

  defp classify({:error, e}), do: {:error, Error.unexpected(Exception.message(e))}

  @doc """
  Creates the cache table, owned by a process that lives as long as the
  application.

  Called from `Mydia.Application.start/2`. An ETS table belongs to the process
  that created it, so creating it lazily from whichever caller arrived first
  would tie the cache's lifetime to a request or job process and destroy it
  when that process exits.
  """
  @spec init_cache() :: :ok
  def init_cache, do: ensure_table()

  defp cached(%MediaServerConfig{id: id}) do
    ensure_table()

    case :ets.lookup(@table, id) do
      [{^id, url, stored_at}] ->
        if System.monotonic_time(:millisecond) - stored_at < @cache_ttl_ms do
          {:ok, url}
        else
          :ets.delete(@table, id)
          :miss
        end

      [] ->
        :miss
    end
  rescue
    # The table vanishing mid-read must degrade to a miss and a re-probe, never
    # take down the caller. A cache is not worth an exception.
    ArgumentError -> :miss
  end

  defp put_cache(%MediaServerConfig{id: id}, url) do
    ensure_table()
    :ets.insert(@table, {id, url, System.monotonic_time(:millisecond)})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end
end
