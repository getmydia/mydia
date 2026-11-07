defmodule Mydia.Downloads.Client.QBittorrent.SessionCache do
  @moduledoc """
  The session cookie each qBittorrent client last logged in with.

  qBittorrent 5.3 caps WebUI sessions (15 by default) and evicts the idlest
  one when a login would exceed the cap. Logging in on every request filled
  that cap within a few polls and kept logging the operator out of their own
  browser session, so the adapter reuses one cookie per client until
  qBittorrent rejects it.

  Entries are keyed by everything that identifies the session: the address
  and the credentials, the password hashed so it is not held in clear twice.
  The GenServer owns the named table and nothing else; reads and writes go
  straight to ETS. A missing table (the app not started) reads as an empty
  cache, so the adapter falls back to logging in.

  Off in test (`config/test.exs`): Bypass reuses ports across tests, and a
  cookie left by one test would let a later one skip the login it asserts on.
  A config enables it with `options: %{session_cache: true}`.
  """

  use GenServer

  @table_name :qbittorrent_session_cache

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Whether `config` should reuse cached sessions."
  @spec enabled?(map()) :: boolean()
  def enabled?(config) do
    case get_in(config, [:options, :session_cache]) do
      nil -> Application.get_env(:mydia, __MODULE__, [])[:enabled] != false
      value -> value == true
    end
  end

  @doc "The cookie stored for `config`, or nil."
  @spec get(map()) :: String.t() | nil
  def get(config) do
    key = key(config)

    case :ets.lookup(@table_name, key) do
      [{^key, cookie}] -> cookie
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @spec put(map(), String.t()) :: :ok
  def put(config, cookie) do
    :ets.insert(@table_name, {key(config), cookie})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec delete(map()) :: :ok
  def delete(config) do
    :ets.delete(@table_name, key(config))
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp key(config) do
    {!!config[:use_ssl], config[:host], config[:port], config[:username],
     :crypto.hash(:sha256, to_string(config[:password]))}
  end

  @impl true
  def init(_opts) do
    :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end
end
