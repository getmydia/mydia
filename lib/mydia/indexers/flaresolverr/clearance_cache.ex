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
  def put(url, cookies, user_agent, now \\ System.os_time(:second)) do
    %URI{host: host} = uri = URI.parse(url)
    matching = Enum.filter(cookies, &domain_matches?(&1, host))

    if matching == [] and is_nil(user_agent) do
      :ignored
    else
      clearance = %Clearance{
        key: key(uri),
        cookies: Enum.map(matching, &{&1.name, &1.value}),
        user_agent: user_agent,
        expires_at: expires_at(matching, now)
      }

      :ets.insert(@table, {clearance.key, clearance})
      :ok
    end
  end

  @spec lookup(String.t(), integer()) :: {:ok, Clearance.t()} | :none
  def lookup(url, now \\ System.os_time(:second)) do
    key = url |> URI.parse() |> key()

    case :ets.lookup(@table, key) do
      [{^key, %Clearance{expires_at: expires_at} = clearance}] when expires_at > now ->
        {:ok, clearance}

      [{^key, _expired}] ->
        :ets.delete(@table, key)
        :none

      [] ->
        :none
    end
  end

  @spec delete(String.t()) :: :ok
  def delete(url) do
    :ets.delete(@table, url |> URI.parse() |> key())
    :ok
  end

  defp key(%URI{host: host, port: port}), do: "#{host}:#{port}"

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
