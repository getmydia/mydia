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

  @type health_status :: :healthy | :unhealthy | :unknown
  @type service_type :: :download_client | :metadata_provider | :indexer | :database
  @type service_id :: String.t()

  @type health_result :: %{
          status: health_status(),
          checked_at: DateTime.t(),
          details: map(),
          error: String.t() | nil
        }

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
