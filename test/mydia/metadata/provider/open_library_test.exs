defmodule Mydia.Metadata.Provider.OpenLibraryTest do
  use ExUnit.Case, async: true

  alias Mydia.Metadata.Provider.OpenLibrary
  alias Mydia.Metadata.Provider.Error
  alias Mydia.Metadata.Structs.{BookMetadata, SearchResult, ImagesResponse}

  # Unit tests that don't require external services
  describe "fetch_images/3" do
    test "returns empty images response for books" do
      # Books don't have the same image structure as movies/TV shows
      # This doesn't make an API call
      config = %{
        type: :open_library,
        base_url: "https://example.com",
        options: %{}
      }

      assert {:ok, images} = OpenLibrary.fetch_images(config, "OL27258W", [])

      assert %ImagesResponse{} = images
      assert images.posters == []
      assert images.backdrops == []
      assert images.logos == []
    end
  end

  describe "fetch_season/4" do
    test "returns invalid request error for books" do
      # Season fetching doesn't apply to books
      config = %{
        type: :open_library,
        base_url: "https://example.com",
        options: %{}
      }

      assert {:error, %Error{type: :invalid_request}} =
               OpenLibrary.fetch_season(config, "OL27258W", 1, [])
    end
  end

  describe "fetch_trending/2" do
    test "returns empty list for books" do
      # Open Library doesn't have trending endpoint
      config = %{
        type: :open_library,
        base_url: "https://example.com",
        options: %{}
      }

      assert {:ok, []} = OpenLibrary.fetch_trending(config, [])
    end
  end

  # External integration tests - these require the metadata-relay service
  # to have OpenLibrary endpoints deployed. Skipped by default.
  @moduletag :external
  @moduletag :openlibrary

  @config %{
    type: :open_library,
    base_url: "https://relay.mydia.dev",
    options: %{
      timeout: 30_000
    }
  }

  describe "test_connection/1 (integration)" do
    @describetag :integration
    test "returns error for invalid base URL" do
      invalid_config = %{@config | base_url: "https://invalid-relay-service.example.com"}

      assert {:error, %Error{type: type}} = OpenLibrary.test_connection(invalid_config)
      assert type in [:connection_failed, :network_error]
    end
  end

  describe "error handling (integration)" do
    @describetag :integration
    test "handles network errors gracefully" do
      config = %{@config | base_url: "https://localhost:99999"}

      assert {:error, %Error{}} = OpenLibrary.search(config, "The Matrix")
    end
  end

  describe "search/3 (integration)" do
    @describetag :integration
    test "searches for books by title" do
      # This test requires the metadata-relay to have OpenLibrary endpoints
      case OpenLibrary.search(@config, "The Hitchhiker's Guide to the Galaxy") do
        {:ok, results} ->
          assert is_list(results)
          assert results != []

          first_result = List.first(results)
          assert %SearchResult{} = first_result
          assert first_result.provider == :open_library
          assert first_result.media_type == :book
          assert is_binary(first_result.title)
          assert is_binary(first_result.provider_id)

        {:error, %Error{type: :api_error, details: %{body: "Not found"}}} ->
          # OpenLibrary endpoints not deployed to relay yet - this is expected
          :ok
      end
    end
  end

  describe "fetch_by_id/3 (integration)" do
    @describetag :integration
    test "fetches book metadata by ISBN" do
      # This test requires the metadata-relay to have OpenLibrary endpoints
      case OpenLibrary.fetch_by_id(@config, "ISBN:9780345391803") do
        {:ok, metadata} ->
          assert %BookMetadata{} = metadata
          assert metadata.provider == :open_library
          assert is_binary(metadata.title)

        {:error, %Error{type: :not_found}} ->
          # OpenLibrary endpoints might return not found
          :ok

        {:error, %Error{type: :api_error, details: %{body: "Not found"}}} ->
          # OpenLibrary endpoints not deployed to relay yet - this is expected
          :ok
      end
    end

    @describetag :integration
    test "fetches book metadata by Open Library Work ID" do
      case OpenLibrary.fetch_by_id(@config, "OL27258W") do
        {:ok, metadata} ->
          assert %BookMetadata{} = metadata
          assert metadata.provider == :open_library
          assert is_binary(metadata.title)

        {:error, %Error{type: :not_found}} ->
          # Work might not exist or endpoints not available
          :ok

        {:error, %Error{type: :api_error, details: %{body: "Not found"}}} ->
          # OpenLibrary endpoints not deployed to relay yet - this is expected
          :ok
      end
    end
  end
end
