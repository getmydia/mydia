defmodule Mydia.Health do
  @moduledoc """
  Health checking system for Mydia services and external integrations.

  This module provides a common interface for health checks across the application,
  including download clients, metadata providers, indexers, and internal services.

  ## Health Status

  Each health check returns a status map with:

  - `:status` - `:healthy`, `:unhealthy`, or `:unknown`
  - `:checked_at` - DateTime when the check was performed
  - `:details` - Additional information (version, capabilities, etc.)
  - `:error` - Error message if unhealthy

  ## Example

      iex> check_health(:download_client, "qbittorrent-main")
      {:ok, %{
        status: :healthy,
        checked_at: ~U[2024-01-01 12:00:00Z],
        details: %{version: "v4.5.0", api_version: "2.8.19"}
      }}
  """

  import Ecto.Query, only: [from: 2]

  alias Mydia.Library.MediaFile
  alias Mydia.Repo

  @type health_status :: :healthy | :unhealthy | :unknown
  @type service_type :: :download_client | :metadata_provider | :indexer | :database
  @type service_id :: String.t()

  @type health_result :: %{
          status: health_status(),
          checked_at: DateTime.t(),
          details: map(),
          error: String.t() | nil
        }

  # A healthy upgrade clears its `supersedes_media_file_id` pointer within a
  # minute or two of import (Mydia.Jobs.UpgradeFinalize runs right after
  # analysis). A generous hour catches genuinely stuck rows without flagging
  # one that is simply still waiting its turn in the analysis queue.
  @upgrade_stuck_threshold_seconds 3600

  @doc """
  Registers a health check provider for a specific service type.

  Health check providers must implement a `check_health/1` function that
  accepts a service identifier and returns `{:ok, health_result}` or
  `{:error, reason}`.
  """
  @spec register_provider(service_type(), module()) :: :ok
  def register_provider(service_type, module) do
    providers = get_providers()
    new_providers = Map.put(providers, service_type, module)
    :persistent_term.put({__MODULE__, :providers}, new_providers)
    :ok
  end

  @doc """
  Performs a health check for a specific service.

  Returns `{:ok, health_result}` if the check was performed successfully,
  or `{:error, reason}` if no provider is registered for the service type.
  """
  @spec check_health(service_type(), service_id()) :: {:ok, health_result()} | {:error, term()}
  def check_health(service_type, service_id) do
    case get_provider(service_type) do
      {:ok, module} ->
        module.check_health(service_id)

      :error ->
        {:error, :no_provider_registered}
    end
  end

  @doc """
  Performs health checks for all registered services of a given type.

  Returns a list of `{service_id, health_result}` tuples.
  """
  @spec check_all(service_type()) :: [{service_id(), health_result()}]
  def check_all(service_type) do
    with {:ok, module} <- get_provider(service_type),
         {:ok, service_ids} <- module.list_services() do
      Enum.map(service_ids, fn service_id ->
        case module.check_health(service_id) do
          {:ok, result} -> {service_id, result}
          {:error, _reason} -> {service_id, unhealthy_result("Health check failed")}
        end
      end)
    else
      _ -> []
    end
  end

  @doc """
  Returns a list of all registered health check providers.
  """
  @spec list_providers() :: [service_type()]
  def list_providers do
    get_providers()
    |> Map.keys()
  end

  @doc """
  Reports media files stuck mid-upgrade.

  An automatic quality upgrade holds two files at once: the freshly
  imported file records which file it `supersedes_media_file_id`, and that
  pointer only clears once `Mydia.Jobs.UpgradeFinalize` scores both files
  for real and trashes the loser. In the healthy case that happens within a
  minute or two of import.

  A pointer still set an hour later means one of two things: the file was
  never analyzed (so finalize was never enqueued), or finalize ran and
  failed after analysis succeeded. Either way the library is quietly
  holding a duplicate file, so both shapes are reported the same way —
  under a single staleness check against `inserted_at`, since neither the
  cause nor the fix depends on which shape it is.

  ## Example

      iex> upgrade_health()
      %{stuck_upgrades: 0}
  """
  @spec upgrade_health() :: %{stuck_upgrades: non_neg_integer()}
  def upgrade_health do
    cutoff = DateTime.add(DateTime.utc_now(), -@upgrade_stuck_threshold_seconds, :second)

    count =
      Repo.aggregate(
        from(f in MediaFile,
          where: not is_nil(f.supersedes_media_file_id) and f.inserted_at < ^cutoff
        ),
        :count
      )

    %{stuck_upgrades: count}
  end

  # Private helpers

  defp get_providers do
    :persistent_term.get({__MODULE__, :providers}, %{})
  end

  defp get_provider(service_type) do
    case Map.fetch(get_providers(), service_type) do
      {:ok, module} -> {:ok, module}
      :error -> :error
    end
  end

  defp unhealthy_result(error_message) do
    %{
      status: :unhealthy,
      checked_at: DateTime.utc_now(),
      details: %{},
      error: error_message
    }
  end
end
