defmodule Mydia.ConfigHelpers do
  @moduledoc """
  Helpers for setting up test configuration, particularly for download clients and indexers.
  """

  alias Mydia.Settings

  @doc """
  Creates a test download client configuration and inserts it into Settings.
  Returns the client configuration map.
  """
  def create_test_download_client(attrs \\ %{}) do
    config = %{
      type: "transmission",
      name: "Test Client #{System.unique_integer([:positive])}",
      host: "localhost",
      port: 9091,
      username: "test",
      password: "test",
      enabled: true
    }

    final_attrs = Map.merge(config, attrs)

    # Create download client config in the database
    {:ok, client_config} = Settings.create_download_client_config(final_attrs)

    client_config
  end

  @doc """
  Creates multiple test download clients.
  Returns a list of client configuration maps.
  """
  def create_test_download_clients(count) when count > 0 do
    Enum.map(1..count, fn i ->
      create_test_download_client(%{
        "name" => "Test Client #{i}",
        "port" => 9090 + i
      })
    end)
  end

  @doc """
  Creates a test indexer configuration and inserts it into the database.
  Returns the indexer configuration struct.
  """
  def create_test_indexer(attrs \\ %{}) do
    config = %{
      type: :prowlarr,
      name: "Test Indexer #{System.unique_integer([:positive])}",
      base_url: "http://localhost:9696",
      api_key: "test_api_key_#{System.unique_integer([:positive])}",
      enabled: true,
      priority: 1
    }

    final_attrs = Map.merge(config, attrs)

    # Create indexer config in the database
    {:ok, indexer_config} = Settings.create_indexer_config(final_attrs)

    indexer_config
  end

  @doc """
  Clears all test configurations from Settings.
  Should be called in test setup to ensure clean state.
  """
  def clear_test_config do
    # Clear download clients
    Settings.list_download_client_configs()
    |> Enum.each(&Settings.delete_download_client_config/1)

    # Clear indexers
    Settings.list_indexer_configs()
    |> Enum.each(&Settings.delete_indexer_config/1)

    :ok
  rescue
    _ -> :ok
  end
end
