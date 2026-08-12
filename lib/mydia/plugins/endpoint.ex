defmodule Mydia.Plugins.Endpoint do
  @moduledoc """
  Resolves a working base URL for an instance-scoped plugin connection.

  A self-hosted service advertises several addresses (a LAN IP, a hostname, a
  reverse-proxy URL) and any of them can stop working when the machine moves
  networks. Storing one frozen address is what produced media server configs
  that timed out for months with no way to recover, so a connection stores an
  ordered candidate list and this module picks the one that answers.

  The winner is cached on the connection in `resolved_base_url` and cleared by
  `invalidate/1` when a request through it fails, so recovery needs no operator
  action.
  """

  alias Mydia.Plugins.Connections
  alias Mydia.Plugins.Error

  require Logger

  @probe_timeout_ms 3_000

  @doc """
  Returns a usable base URL for `connection`.

  Uses the cached winner when it is still one of the candidates. Otherwise
  probes candidates in order and caches the first that answers.

  ## Options

    * `:probe` - `(url -> :ok | {:error, term})`, injected in tests
    * `:probe_path` - path appended when probing (default `"/"`)
  """
  @spec resolve(Connections.t(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def resolve(%Connections{} = connection, opts \\ []) do
    candidates = normalize(connection.base_urls)

    cond do
      candidates == [] ->
        {:error, Error.new(:invalid_request, "connection #{connection.label} has no address")}

      connection.resolved_base_url in candidates ->
        {:ok, connection.resolved_base_url}

      true ->
        probe_all(connection, candidates, opts)
    end
  end

  @doc "Clears the cached winner so the next `resolve/2` re-probes."
  @spec invalidate(Connections.t()) :: :ok
  def invalidate(%Connections{} = connection) do
    {:ok, _} = Connections.set_resolved_base_url(connection, nil)
    :ok
  end

  defp probe_all(connection, candidates, opts) do
    probe = Keyword.get(opts, :probe, &default_probe(&1, opts))

    case Enum.find(candidates, fn url -> probe.(url) == :ok end) do
      nil ->
        Logger.warning("no endpoint candidate answered",
          plugin: connection.plugin_slug,
          label: connection.label
        )

        {:error, Error.new(:network_error, "no address for #{connection.label} answered")}

      winner ->
        {:ok, _} = Connections.set_resolved_base_url(connection, winner)
        {:ok, winner}
    end
  end

  defp default_probe(url, opts) do
    path = Keyword.get(opts, :probe_path, "/")

    case Req.get(url <> path,
           receive_timeout: @probe_timeout_ms,
           retry: false,
           redirect: false
         ) do
      {:ok, %{status: status}} when status < 500 -> :ok
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize(nil), do: []

  defp normalize(urls) when is_list(urls) do
    urls
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim_trailing(&1, "/"))
    |> Enum.reject(&(&1 == ""))
  end
end
