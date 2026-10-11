defmodule Mydia.Indexers.FlareSolverr.ClearanceCache do
  @moduledoc """
  In-memory clearance per host, so a solved site is searched directly until
  its clearance expires instead of through FlareSolverr every time.

  This is Prowlarr's model: FlareSolverr solves, the request is repeated
  directly with the solution's cookies and user-agent, and the pair is reused.
  Keyed by host and port, never by indexer, so a clearance is only ever sent to
  the host that issued it and a mirror failover starts clean. Memory only: a
  restart costs one solve per host, and nothing shares the
  `cardigann_search_sessions` table that holds tracker logins.
  """

  use GenServer

  alias Mydia.Indexers.FlareSolverr.Clearance

  @table :mydia_flaresolverr_clearance
  @default_ttl_seconds 30 * 60

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @spec put(String.t(), list(), String.t() | nil, integer()) :: :ok | :ignored
  # The ETS calls below raise ArgumentError while the owning process is down or
  # restarting. They sit on the search path, and a missing cache only costs a
  # solve, so they fail soft instead of failing the search.
  def put(url, cookies, user_agent, now \\ System.os_time(:second)) do
    with {:ok, key, host} <- key(url) do
      matching = Enum.filter(cookies, &domain_matches?(&1, host))

      if matching == [] and is_nil(user_agent) do
        :ignored
      else
        clearance = %Clearance{
          key: key,
          cookies: Enum.map(matching, &{&1.name, &1.value}),
          user_agent: user_agent,
          expires_at: expires_at(matching, now)
        }

        :ets.insert(@table, {key, clearance})
        :ok
      end
    else
      :error -> :ignored
    end
  rescue
    ArgumentError -> :ignored
  end

  @spec lookup(String.t(), integer()) :: {:ok, Clearance.t()} | :none
  def lookup(url, now \\ System.os_time(:second)) do
    with {:ok, key, _host} <- key(url) do
      case :ets.lookup(@table, key) do
        [{^key, %Clearance{expires_at: expires_at} = clearance}] when expires_at > now ->
          {:ok, clearance}

        [{^key, _expired}] ->
          :ets.delete(@table, key)
          :none

        [] ->
          :none
      end
    else
      :error -> :none
    end
  rescue
    ArgumentError -> :none
  end

  @spec delete(String.t()) :: :ok
  def delete(url) do
    with {:ok, key, _host} <- key(url) do
      :ets.delete(@table, key)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  # A URL without a host has no clearance to hold: every such URL would share
  # one key and be handed each other's user-agent. Hosts are case-insensitive.
  defp key(url) do
    case URI.parse(url) do
      %URI{host: host, port: port} when is_binary(host) and host != "" ->
        host = String.downcase(host)
        {:ok, "#{host}:#{port}", host}

      _ ->
        :error
    end
  end

  # RFC 6265 domain matching: ".example.com" and "example.com" both cover
  # example.com and its subdomains.
  defp domain_matches?(%{domain: domain}, host) when is_binary(domain) and is_binary(host) do
    domain = domain |> String.trim_leading(".") |> String.downcase()
    host = String.downcase(host)
    host == domain or String.ends_with?(host, "." <> domain)
  end

  defp domain_matches?(_cookie, _host), do: false

  # Session cookies report expires -1. Only a real future expiry shortens the
  # default lifetime.
  defp expires_at(cookies, now) do
    cookies
    |> Enum.map(& &1.expires)
    |> Enum.filter(&(is_number(&1) and &1 > now))
    |> Enum.map(&trunc/1)
    |> Enum.min(fn -> now + @default_ttl_seconds end)
  end
end
