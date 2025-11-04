defmodule MydiaWeb.Api.DownloadClientController do
  @moduledoc """
  REST API controller for download client management and health status.

  Provides endpoints to query download client configurations and health status.
  """

  use MydiaWeb, :controller

  alias Mydia.Settings
  alias Mydia.Downloads.ClientHealth

  @doc """
  Lists all download client configurations with health status.

  GET /api/v1/downloads/clients

  Returns:
    - 200: List of download clients with health status
  """
  def index(conn, _params) do
    clients = Settings.list_download_client_configs()
    health_checks = ClientHealth.check_all_clients() |> Map.new()

    clients_with_health =
      Enum.map(clients, fn client ->
        health = Map.get(health_checks, client.id, %{status: :unknown})

        %{
          id: client.id,
          name: client.name,
          type: client.type,
          enabled: client.enabled,
          priority: client.priority,
          host: client.host,
          port: client.port,
          use_ssl: client.use_ssl,
          health: health
        }
      end)

    json(conn, %{data: clients_with_health})
  end

  @doc """
  Gets a specific download client configuration with health status.

  GET /api/v1/downloads/clients/:id

  Returns:
    - 200: Download client with health status
    - 404: Client not found
  """
  def show(conn, %{"id" => id}) do
    case Settings.get_download_client_config!(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Download client not found"})

      client ->
        {:ok, health} = ClientHealth.check_health(id)

        client_with_health = %{
          id: client.id,
          name: client.name,
          type: client.type,
          enabled: client.enabled,
          priority: client.priority,
          host: client.host,
          port: client.port,
          use_ssl: client.use_ssl,
          url_base: client.url_base,
          category: client.category,
          download_directory: client.download_directory,
          health: health
        }

        json(conn, %{data: client_with_health})
    end
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{error: "Download client not found"})
  end

  @doc """
  Tests connection to a specific download client (forces fresh check).

  POST /api/v1/downloads/clients/:id/test

  Returns:
    - 200: Test result with health status
    - 404: Client not found
  """
  def test(conn, %{"id" => id}) do
    case ClientHealth.check_health(id, force: true) do
      {:ok, health} ->
        json(conn, %{data: health})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Download client not found"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  @doc """
  Forces a refresh of all download client health checks.

  POST /api/v1/downloads/clients/refresh

  Returns:
    - 202: Refresh initiated
  """
  def refresh(conn, _params) do
    ClientHealth.refresh_all_clients()

    conn
    |> put_status(:accepted)
    |> json(%{message: "Health check refresh initiated"})
  end
end
