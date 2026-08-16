defmodule Mydia.Metadata.CollectionFetchTest do
  use ExUnit.Case, async: false

  alias Mydia.Metadata
  alias Mydia.Metadata.Cache
  alias Mydia.Metadata.Structs.Collection

  setup do
    bypass = Bypass.open()

    config = %{
      type: :metadata_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{language: "en-US", include_adult: false}
    }

    %{bypass: bypass, config: config}
  end

  defp collection_body(id) do
    %{
      "id" => id,
      "name" => "Test Collection #{id}",
      "parts" => [
        %{"id" => id + 1, "title" => "First", "release_date" => "2001-01-01"},
        %{"id" => id + 2, "title" => "Second", "release_date" => "2004-01-01"}
      ]
    }
  end

  test "fetches and parses a collection", %{bypass: bypass, config: config} do
    id = System.unique_integer([:positive])
    on_exit(fn -> Cache.delete("collection:metadata_relay:#{id}:en-US") end)

    Bypass.expect_once(bypass, "GET", "/tmdb/collections/#{id}", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(collection_body(id)))
    end)

    assert {:ok, %Collection{} = collection} = Metadata.fetch_collection_cached(config, id)
    assert collection.name == "Test Collection #{id}"
    assert length(collection.parts) == 2
  end

  test "serves the second call from cache", %{bypass: bypass, config: config} do
    id = System.unique_integer([:positive])
    on_exit(fn -> Cache.delete("collection:metadata_relay:#{id}:en-US") end)

    # expect_once fails the test if the endpoint is hit twice
    Bypass.expect_once(bypass, "GET", "/tmdb/collections/#{id}", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(collection_body(id)))
    end)

    assert {:ok, first} = Metadata.fetch_collection_cached(config, id)
    assert {:ok, second} = Metadata.fetch_collection_cached(config, id)
    assert first == second
  end

  test "different languages do not share a cache entry", %{bypass: bypass, config: config} do
    id = System.unique_integer([:positive])

    on_exit(fn ->
      Cache.delete("collection:metadata_relay:#{id}:en-US")
      Cache.delete("collection:metadata_relay:#{id}:fr-FR")
    end)

    Bypass.expect(bypass, "GET", "/tmdb/collections/#{id}", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(collection_body(id)))
    end)

    assert {:ok, _} = Metadata.fetch_collection_cached(config, id)
    assert {:ok, _} = Metadata.fetch_collection_cached(config, id, language: "fr-FR")

    # Both keys are populated independently
    assert {:ok, _} = Cache.get("collection:metadata_relay:#{id}:en-US")
    assert {:ok, _} = Cache.get("collection:metadata_relay:#{id}:fr-FR")
  end

  test "a relay without the endpoint returns not_found", %{bypass: bypass, config: config} do
    id = System.unique_integer([:positive])
    on_exit(fn -> Cache.delete("collection:metadata_relay:#{id}:en-US") end)

    Bypass.expect_once(bypass, "GET", "/tmdb/collections/#{id}", fn conn ->
      Plug.Conn.resp(conn, 404, "Not Found")
    end)

    assert {:error, %{type: :not_found}} = Metadata.fetch_collection_cached(config, id)
  end

  test "a server error is not cached", %{bypass: bypass, config: config} do
    id = System.unique_integer([:positive])
    on_exit(fn -> Cache.delete("collection:metadata_relay:#{id}:en-US") end)

    Bypass.expect(bypass, "GET", "/tmdb/collections/#{id}", fn conn ->
      Plug.Conn.resp(conn, 500, "boom")
    end)

    assert {:error, _} = Metadata.fetch_collection_cached(config, id)
    assert {:error, :not_found} = Cache.get("collection:metadata_relay:#{id}:en-US")
  end

  # Collections are a TMDB concept served by the relay, and :metadata_relay is
  # the only provider type that can answer for one. Any other type must be
  # rejected rather than quietly routed to the relay adapter under a cache key
  # that claims otherwise.
  test "a non-relay config is rejected without reaching the relay", %{bypass: bypass} do
    id = System.unique_integer([:positive])

    Bypass.down(bypass)

    config = %{
      type: :not_the_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{language: "en-US"}
    }

    assert {:error, %{type: :invalid_config}} = Metadata.fetch_collection_cached(config, id)
  end

  test "a rejected config is not cached under any key", %{bypass: bypass} do
    id = System.unique_integer([:positive])

    config = %{
      type: :also_not_the_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{language: "en-US"}
    }

    assert {:error, %{type: :invalid_config}} = Metadata.fetch_collection_cached(config, id)
    assert {:error, :not_found} = Cache.get("collection:also_not_the_relay:#{id}:en-US")
    assert {:error, :not_found} = Cache.get("collection:metadata_relay:#{id}:en-US")
  end
end
