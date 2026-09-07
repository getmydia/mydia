defmodule Mydia.P2p.RelayList do
  @moduledoc """
  Resolves which iroh relays this install should use.

  The relay hostname used to be compiled in, so moving it meant shipping a new
  server image and waiting for every install to upgrade. This reads the list
  from the metadata relay's `/client-config` at boot instead, so a relay move
  is a relay deploy.

  Precedence, highest first:

    1. An explicit `IROH_RELAY_URL`. Used alone, and the fetch is skipped
       entirely. Someone who set it did so to pin their install to one relay,
       so merging mydia's list into theirs would defeat the setting.
    2. `p2p.relays` from a successful fetch.
    3. The last successful fetch, read from disk.
    4. The compiled-in default.

  iroh's own public relays are appended underneath whatever this returns, by
  `build_relay_mode` in `native/mydia_p2p_core/src/lib.rs`. That is why losing
  a mydia relay degrades rather than breaks, and why this module never needs to
  carry them.

  The fetch goes to the *configured* metadata relay, not a hardcoded
  `relay.mydia.dev`, so a self-hoster running their own relay serves their own
  list and no install gains a network dependency it did not already have.

  `player/lib/core/p2p/relay_list.dart` is the Dart twin of this module and
  implements the same four levels and the same validation.
  """

  require Logger

  alias Mydia.Metadata

  @default_relay_url "https://cae1-1.relay.mydia.dev"
  @timeout_ms 3_000
  @path "/client-config"

  @type source :: :override | :fetched | :cached | :default

  @doc """
  The relay compiled into this build, used when nothing else is available.
  """
  @spec default_relay_url() :: String.t()
  def default_relay_url, do: @default_relay_url

  @doc """
  Resolves the relay list.

  Returns the URLs and which precedence level produced them, so the caller can
  log something honest at boot.

  Options exist for tests: `:cache_path`, `:base_url`, `:req_options` and
  `:override`. In production all four come from the environment.
  """
  @spec resolve(keyword()) :: {[String.t()], source()}
  def resolve(opts \\ []) do
    case override(opts) do
      [_ | _] = urls -> {urls, :override}
      [] -> resolve_from_relay(opts)
    end
  end

  defp resolve_from_relay(opts) do
    cache_path = Keyword.get(opts, :cache_path) || default_cache_path()

    case fetch(opts) do
      [_ | _] = urls ->
        write_cache(cache_path, urls)
        {urls, :fetched}

      [] ->
        case read_cache(cache_path) do
          [_ | _] = urls -> {urls, :cached}
          [] -> {[@default_relay_url], :default}
        end
    end
  end

  defp override(opts) do
    raw =
      case Keyword.fetch(opts, :override) do
        {:ok, value} -> value
        :error -> System.get_env("IROH_RELAY_URL")
      end

    # System.get_env/1 returns "" for a variable explicitly set empty, and ""
    # is truthy in Elixir, so trimming is what actually treats blank as unset.
    case raw do
      nil -> []
      value -> value |> String.trim() |> List.wrap() |> valid_urls()
    end
  end

  defp fetch(opts) do
    base_url = Keyword.get(opts, :base_url) || Metadata.default_relay_config().base_url
    req_options = Keyword.get(opts, :req_options, [])

    req =
      Req.new(
        base_url: base_url,
        receive_timeout: @timeout_ms,
        connect_options: [timeout: @timeout_ms],
        retry: false,
        headers: [accept: "application/json"]
      )
      |> Req.merge(req_options)

    case Req.get(req, url: @path) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        relays_from(body)

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("Relay list fetch returned HTTP #{status}, falling back")
        []

      {:error, reason} ->
        Logger.warning("Relay list fetch failed: #{inspect(reason)}, falling back")
        []
    end
  rescue
    e ->
      Logger.warning("Relay list fetch raised: #{inspect(e)}, falling back")
      []
  end

  # Unknown keys are ignored on purpose: the document is meant to grow without
  # a client change.
  defp relays_from(%{"p2p" => %{"relays" => relays}}) when is_list(relays),
    do: valid_urls(relays)

  defp relays_from(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> relays_from(decoded)
      {:error, _} -> []
    end
  end

  defp relays_from(_), do: []

  defp valid_urls(urls) do
    Enum.filter(urls, fn
      url when is_binary(url) ->
        case URI.parse(url) do
          %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> true
          _ -> false
        end

      _ ->
        false
    end)
  end

  defp read_cache(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, urls} when is_list(urls) <- Jason.decode(contents) do
      valid_urls(urls)
    else
      _ -> []
    end
  end

  defp write_cache(path, urls) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, Jason.encode!(urls))
  rescue
    e ->
      # A cache we cannot write costs us the next offline boot, nothing more.
      Logger.warning("Could not cache the relay list at #{path}: #{inspect(e)}")
      :ok
  end

  defp default_cache_path do
    keypair_path =
      Application.get_env(:mydia, :p2p_keypair_path) ||
        raise "p2p_keypair_path is not configured"

    Path.join(Path.dirname(keypair_path), "relays.json")
  end
end
