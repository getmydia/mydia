defmodule Mydia.RemoteAccess.Provision do
  @moduledoc """
  Ensures this instance has a remote access config row, and seeds the enabled cache.

  The row used to be created only when an administrator first opened the remote
  access admin page, so most installs have none. Pairing is a normal user action
  now, so the identity it depends on has to exist without an administrator
  having visited anything.

  Runs as a supervised `Task` ahead of `Mydia.P2p.Server`.
  """

  use Task

  require Logger

  alias Mydia.RemoteAccess

  def start_link(_arg) do
    Task.start_link(&run/0)
  end

  @doc """
  Creates the config row when absent, then reseeds `RemoteAccess.enabled?/0`.

  An existing row is left exactly as it is, including its `enabled` value: an
  operator who turned remote access off after upgrading meant it.
  """
  @spec run() :: :ok
  def run do
    # initialize_config/0 returns an existing row untouched, so an operator who
    # turned remote access off after upgrading keeps it off.
    case RemoteAccess.initialize_config() do
      {:ok, config} ->
        Logger.info("Remote access config ready, instance ID #{config.instance_id}")

      {:error, changeset} ->
        Logger.error("Remote access provisioning failed: #{inspect(changeset.errors)}")
    end

    RemoteAccess.refresh_enabled_cache()
    :ok
  end
end
