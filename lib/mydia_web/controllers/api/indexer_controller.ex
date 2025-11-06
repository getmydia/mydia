defmodule MydiaWeb.Api.IndexerController do
  @moduledoc """
  REST API controller for indexer management and health status.

  Provides endpoints to query indexer configurations, health status,
  and rate limit statistics.
  """

  use MydiaWeb, :controller

  alias Mydia.Settings
  alias Mydia.Indexers.Health
  alias Mydia.Indexers.RateLimiter

  @doc """
  Lists all indexer configurations with health status.

  GET /api/v1/indexers

  Returns:
    - 200: List of indexers with health and rate limit status
  """
  def index(conn, _params) do
    indexers = Settings.list_indexer_configs()
    health_checks = Health.check_all_indexers() |> Map.new()

    indexers_with_health =
      Enum.map(indexers, fn indexer ->
        health = Map.get(health_checks, indexer.id, %{status: :unknown})
        rate_limit_stats = RateLimiter.get_stats(indexer.id)
        failure_count = Health.get_failure_count(indexer.id)

        %{
          id: indexer.id,
          name: indexer.name,
          type: indexer.type,
          enabled: indexer.enabled,
          priority: indexer.priority,
          base_url: indexer.base_url,
          rate_limit: indexer.rate_limit,
          health: health,
          rate_limit_stats: rate_limit_stats,
          consecutive_failures: failure_count
        }
      end)

    json(conn, %{data: indexers_with_health})
  end

  @doc """
  Gets a specific indexer configuration with health status.

  GET /api/v1/indexers/:id

  Returns:
    - 200: Indexer with health and rate limit status
    - 404: Indexer not found
  """
  def show(conn, %{"id" => id}) do
    case Settings.get_indexer_config!(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Indexer not found"})

      indexer ->
        {:ok, health} = Health.check_health(id)
        rate_limit_stats = RateLimiter.get_stats(id)
        failure_count = Health.get_failure_count(id)

        indexer_with_health = %{
          id: indexer.id,
          name: indexer.name,
          type: indexer.type,
          enabled: indexer.enabled,
          priority: indexer.priority,
          base_url: indexer.base_url,
          api_key: if(indexer.api_key, do: "***", else: nil),
          indexer_ids: indexer.indexer_ids,
          categories: indexer.categories,
          rate_limit: indexer.rate_limit,
          connection_settings: indexer.connection_settings,
          health: health,
          rate_limit_stats: rate_limit_stats,
          consecutive_failures: failure_count
        }

        json(conn, %{data: indexer_with_health})
    end
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{error: "Indexer not found"})
  end

  @doc """
  Tests connection to a specific indexer (forces fresh check).

  POST /api/v1/indexers/:id/test

  Returns:
    - 200: Test result with health status
    - 404: Indexer not found
  """
  def test(conn, %{"id" => id}) do
    case Health.check_health(id, force: true) do
      {:ok, health} ->
        json(conn, %{data: health})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Indexer not found"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  @doc """
  Forces a refresh of all indexer health checks.

  POST /api/v1/indexers/refresh

  Returns:
    - 202: Refresh initiated
  """
  def refresh(conn, _params) do
    Health.refresh_all_indexers()

    conn
    |> put_status(:accepted)
    |> json(%{message: "Health check refresh initiated"})
  end

  @doc """
  Resets the failure counter for a specific indexer.

  POST /api/v1/indexers/:id/reset-failures

  Returns:
    - 200: Failure counter reset
    - 404: Indexer not found
  """
  def reset_failures(conn, %{"id" => id}) do
    case Settings.get_indexer_config!(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Indexer not found"})

      _indexer ->
        Health.reset_failures(id)

        json(conn, %{message: "Failure counter reset successfully"})
    end
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{error: "Indexer not found"})
  end
end
