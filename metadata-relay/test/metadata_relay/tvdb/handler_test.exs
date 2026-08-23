defmodule MetadataRelay.TVDB.HandlerTest do
  use ExUnit.Case, async: false

  alias MetadataRelay.TVDB.Auth
  alias MetadataRelay.TVDB.Handler
  alias MetadataRelay.Test.TVDBHelpers

  @moduletag :tvdb
  @moduletag :capture_log

  setup do
    # Set a test API key to avoid the missing key error
    System.put_env("TVDB_API_KEY", "test_api_key_12345")

    on_exit(fn ->
      TVDBHelpers.clear_tvdb_adapter()
      System.delete_env("TVDB_API_KEY")
    end)

    :ok
  end

  # Helper to setup Auth with default name for Handler tests
  # The Handler module uses the default Auth GenServer name, so we start it with that name
  defp setup_handler_test(routes) do
    token = TVDBHelpers.create_test_token()

    # Add auth route to all route maps
    routes_with_auth = Map.put(routes, "/v4/login", {200, %{"data" => %{"token" => token}}})

    adapter = TVDBHelpers.mock_adapter_with_routes(routes_with_auth)
    TVDBHelpers.set_tvdb_adapter(adapter)

    # Stop existing Auth if running (from previous test)
    if pid = GenServer.whereis(Auth) do
      GenServer.stop(pid)
    end

    # Start with default name (Auth module uses its own module name as default)
    {:ok, auth_pid} = Auth.start_link()
    auth_pid
  end

  describe "search/1" do
    test "searches for series by query" do
      auth_pid =
        setup_handler_test(%{
          "/v4/search" =>
            {200, %{"data" => [%{"id" => 123, "name" => "Breaking Bad", "type" => "series"}]}}
        })

      result = Handler.search(query: "Breaking Bad")

      GenServer.stop(auth_pid)

      assert {:ok, %{"data" => [%{"id" => 123, "name" => "Breaking Bad", "type" => "series"}]}} =
               result
    end

    test "searches with type filter" do
      auth_pid =
        setup_handler_test(%{
          "/v4/search" =>
            {200, %{"data" => [%{"id" => 456, "name" => "The Matrix", "type" => "movie"}]}}
        })

      result = Handler.search(query: "Matrix", type: "movie")

      GenServer.stop(auth_pid)

      assert {:ok, %{"data" => [%{"id" => 456, "name" => "The Matrix", "type" => "movie"}]}} =
               result
    end

    test "searches with year filter" do
      auth_pid =
        setup_handler_test(%{
          "/v4/search" => {200, %{"data" => [%{"id" => 789, "name" => "Dune", "year" => "2021"}]}}
        })

      result = Handler.search(query: "Dune", year: "2021")

      GenServer.stop(auth_pid)

      assert {:ok, %{"data" => [%{"id" => 789, "name" => "Dune", "year" => "2021"}]}} = result
    end

    test "returns empty results for no matches" do
      auth_pid =
        setup_handler_test(%{
          "/v4/search" => {200, %{"data" => []}}
        })

      result = Handler.search(query: "NonExistentShowXYZ123")

      GenServer.stop(auth_pid)

      assert {:ok, %{"data" => []}} = result
    end
  end

  describe "get_series/2" do
    test "retrieves series by ID" do
      auth_pid =
        setup_handler_test(%{
          "/v4/series/81189" =>
            {200, %{"data" => %{"id" => 81189, "name" => "Breaking Bad", "status" => "Ended"}}}
        })

      result = Handler.get_series("81189")

      GenServer.stop(auth_pid)

      assert {:ok, %{"data" => %{"id" => 81189, "name" => "Breaking Bad", "status" => "Ended"}}} =
               result
    end

    test "handles series not found" do
      auth_pid =
        setup_handler_test(%{
          "/v4/series/999999999" => {404, %{"error" => "Resource not found"}}
        })

      result = Handler.get_series("999999999")

      GenServer.stop(auth_pid)

      assert {:error, {:http_error, 404, %{"error" => "Resource not found"}}} = result
    end
  end

  describe "get_series_extended/2" do
    test "retrieves extended series info" do
      auth_pid =
        setup_handler_test(%{
          "/v4/series/81189/extended" =>
            {200,
             %{
               "data" => %{
                 "id" => 81189,
                 "name" => "Breaking Bad",
                 "episodes" => [%{"id" => 1, "name" => "Pilot"}],
                 "characters" => []
               }
             }}
        })

      result = Handler.get_series_extended("81189", [])

      GenServer.stop(auth_pid)

      assert {:ok, %{"data" => %{"id" => 81189, "name" => "Breaking Bad"}}} = result
    end

    test "retrieves extended series with meta options" do
      auth_pid =
        setup_handler_test(%{
          "/v4/series/81189/extended" =>
            {200,
             %{
               "data" => %{
                 "id" => 81189,
                 "translations" => [%{"language" => "eng"}]
               }
             }}
        })

      result = Handler.get_series_extended("81189", meta: "translations")

      GenServer.stop(auth_pid)

      assert {:ok, %{"data" => %{"id" => 81189, "translations" => _}}} = result
    end
  end

  describe "get_series_episodes/2" do
    test "retrieves episodes for a series" do
      auth_pid =
        setup_handler_test(%{
          "/v4/series/81189/episodes/default/page/0" =>
            {200,
             %{
               "data" => %{
                 "episodes" => [
                   %{"id" => 1, "name" => "Pilot", "seasonNumber" => 1, "episodeNumber" => 1}
                 ]
               }
             }}
        })

      result = Handler.get_series_episodes("81189", %{})

      GenServer.stop(auth_pid)

      assert {:ok, %{"data" => %{"episodes" => [%{"id" => 1, "name" => "Pilot"}]}}} = result
    end

    test "retrieves episodes with pagination" do
      auth_pid =
        setup_handler_test(%{
          "/v4/series/81189/episodes/default/page/2" =>
            {200,
             %{
               "data" => %{
                 "episodes" => [
                   %{"id" => 100, "name" => "Episode 100"}
                 ]
               }
             }}
        })

      result = Handler.get_series_episodes("81189", %{"page" => 2})

      GenServer.stop(auth_pid)

      assert {:ok, %{"data" => %{"episodes" => [%{"id" => 100}]}}} = result
    end
  end

  describe "get_season/2" do
    test "retrieves season by ID" do
      auth_pid =
        setup_handler_test(%{
          "/v4/seasons/12345" =>
            {200,
             %{
               "data" => %{
                 "id" => 12345,
                 "seriesId" => 81189,
                 "number" => 1
               }
             }}
        })

      result = Handler.get_season("12345")

      GenServer.stop(auth_pid)

      assert {:ok, %{"data" => %{"id" => 12345, "number" => 1}}} = result
    end
  end

  describe "get_season_extended/2" do
    test "retrieves extended season info" do
      auth_pid =
        setup_handler_test(%{
          "/v4/seasons/12345/extended" =>
            {200,
             %{
               "data" => %{
                 "id" => 12345,
                 "episodes" => [%{"id" => 1}, %{"id" => 2}]
               }
             }}
        })

      result = Handler.get_season_extended("12345", [])

      GenServer.stop(auth_pid)

      assert {:ok, %{"data" => %{"id" => 12345, "episodes" => _}}} = result
    end
  end

  describe "get_episode/2" do
    test "retrieves episode by ID" do
      auth_pid =
        setup_handler_test(%{
          "/v4/episodes/123456" =>
            {200,
             %{
               "data" => %{
                 "id" => 123_456,
                 "name" => "Pilot",
                 "seasonNumber" => 1,
                 "episodeNumber" => 1
               }
             }}
        })

      result = Handler.get_episode("123456")

      GenServer.stop(auth_pid)

      assert {:ok, %{"data" => %{"id" => 123_456, "name" => "Pilot"}}} = result
    end
  end

  describe "get_episode_extended/2" do
    test "retrieves extended episode info" do
      auth_pid =
        setup_handler_test(%{
          "/v4/episodes/123456/extended" =>
            {200,
             %{
               "data" => %{
                 "id" => 123_456,
                 "name" => "Pilot",
                 "characters" => [],
                 "translations" => []
               }
             }}
        })

      result = Handler.get_episode_extended("123456", [])

      GenServer.stop(auth_pid)

      assert {:ok, %{"data" => %{"id" => 123_456}}} = result
    end
  end

  describe "get_artwork/2" do
    test "retrieves artwork by ID" do
      auth_pid =
        setup_handler_test(%{
          "/v4/artwork/789012" =>
            {200,
             %{
               "data" => %{
                 "id" => 789_012,
                 "type" => 1,
                 "thumbnail" => "https://artworks.thetvdb.com/banners/posters/81189-1.jpg"
               }
             }}
        })

      result = Handler.get_artwork("789012")

      GenServer.stop(auth_pid)

      assert {:ok, %{"data" => %{"id" => 789_012, "type" => 1}}} = result
    end

    test "handles artwork not found" do
      auth_pid =
        setup_handler_test(%{
          "/v4/artwork/999999999" => {404, %{"error" => "Resource not found"}}
        })

      result = Handler.get_artwork("999999999")

      GenServer.stop(auth_pid)

      assert {:error, {:http_error, 404, %{"error" => "Resource not found"}}} = result
    end
  end

  describe "error handling" do
    test "handles authentication errors" do
      token = TVDBHelpers.create_test_token()

      # The adapter needs to fail refresh too
      request_count = :counters.new(1, [:atomics])

      custom_adapter = fn request ->
        :counters.add(request_count, 1, 1)
        count = :counters.get(request_count, 1)
        url = request.url |> URI.to_string()

        cond do
          String.contains?(url, "/v4/login") ->
            if count <= 1 do
              {request, Req.Response.new(status: 200, body: %{"data" => %{"token" => token}})}
            else
              # Refresh fails
              {request, Req.Response.new(status: 401, body: %{"error" => "Invalid API key"})}
            end

          String.contains?(url, "/v4/search") ->
            {request, Req.Response.new(status: 401, body: %{"error" => "Invalid token"})}

          true ->
            {request, Req.Response.new(status: 404, body: %{"error" => "Not found"})}
        end
      end

      TVDBHelpers.set_tvdb_adapter(custom_adapter)

      # Stop existing Auth if running (from previous test)
      if pid = GenServer.whereis(Auth) do
        GenServer.stop(pid)
      end

      # Start with default name (required by Handler)
      {:ok, auth_pid} = Auth.start_link()

      result = Handler.search(query: "test")

      GenServer.stop(auth_pid)

      assert {:error, {:authentication_failed, {:http_error, 401, _}}} = result
    end

    test "handles server errors" do
      auth_pid =
        setup_handler_test(%{
          "/v4/series/123" => {500, %{"error" => "Internal server error"}}
        })

      result = Handler.get_series("123")

      GenServer.stop(auth_pid)

      assert {:error, {:http_error, 500, %{"error" => "Internal server error"}}} = result
    end

    test "handles rate limiting" do
      auth_pid =
        setup_handler_test(%{
          "/v4/search" => {429, %{"error" => "Too many requests"}}
        })

      result = Handler.search(query: "test")

      GenServer.stop(auth_pid)

      assert {:error, {:http_error, 429, %{"error" => "Too many requests"}}} = result
    end
  end
end
