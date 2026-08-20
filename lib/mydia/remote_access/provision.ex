defmodule Mydia.RemoteAccess.Provision do
  @moduledoc """
  Ensures this instance has a remote access config row, and seeds the enabled cache.

  The row used to be created only when an administrator first opened the remote
  access admin page, so most installs have none. Pairing is a normal user action
  now, so the identity it depends on has to exist without an administrator
  having visited anything.

  Runs as a supervised `Task` ahead of `Mydia.P2p.Server`.
  """

  require Logger

  alias Mydia.RemoteAccess

  @doc """
  Child spec that provisions synchronously, then bows out.

  Deliberately not a `Task`: `Task.start_link/1` returns as soon as the process
  is spawned, so the supervisor would move on to `Mydia.P2p.Server` while the
  config row and the enabled cache were still absent. Running the work inside
  `start_link/1` and returning `:ignore` makes the ordering real, since the
  supervisor does not start the next child until this call returns.
  """
  def child_spec(arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}, restart: :transient}
  end

  def start_link(_arg) do
    case run() do
      :ok -> :ignore
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates the config row when absent, then reseeds `RemoteAccess.enabled?/0`.

  An existing row is left exactly as it is, including its `enabled` value: an
  operator who turned remote access off after upgrading meant it.
  """
  @spec run() :: :ok | {:error, term()}
  def run do
    # initialize_config/0 returns an existing row untouched, so an operator who
    # turned remote access off after upgrading keeps it off.
    case RemoteAccess.initialize_config() do
      {:ok, config} ->
        Logger.info("Remote access config ready, instance ID #{config.instance_id}")
        RemoteAccess.refresh_enabled_cache()
        :ok

      {:error, changeset} ->
        # Failing loudly beats booting a p2p node with no instance identity:
        # every pairing depends on the row this was supposed to create.
        Logger.error("Remote access provisioning failed: #{inspect(changeset.errors)}")
        {:error, {:remote_access_provisioning_failed, changeset.errors}}
    end
  end
end
