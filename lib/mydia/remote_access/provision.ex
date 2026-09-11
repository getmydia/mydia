defmodule Mydia.RemoteAccess.Provision do
  @moduledoc """
  Ensures this instance has a remote access config row.

  The row holds the instance identity every pairing depends on, so it has to
  exist before `Mydia.P2p.Server` starts. Runs first in
  `Mydia.Player.RemoteAccess.Supervisor`.
  """

  require Logger

  alias Mydia.RemoteAccess

  @doc """
  Child spec that provisions synchronously, then bows out.

  Deliberately not a `Task`: `Task.start_link/1` returns as soon as the process
  is spawned, so the supervisor would move on to `Mydia.P2p.Server` while the
  config row was still absent. Running the work inside
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

  @doc "Creates the config row when absent. An existing row is left as it is."
  @spec run() :: :ok | {:error, term()}
  def run do
    case RemoteAccess.initialize_config() do
      {:ok, config} ->
        Logger.info("Remote access config ready, instance ID #{config.instance_id}")
        :ok

      {:error, changeset} ->
        # Failing loudly beats booting a p2p node with no instance identity:
        # every pairing depends on the row this was supposed to create.
        Logger.error("Remote access provisioning failed: #{inspect(changeset.errors)}")
        {:error, {:remote_access_provisioning_failed, changeset.errors}}
    end
  end
end
