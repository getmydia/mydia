defmodule MetadataRelay.TMDB.HandlerTest do
  use ExUnit.Case, async: false

  alias MetadataRelay.Router
  alias MetadataRelay.TMDB.Handler
  alias MetadataRelay.Test.TMDBHelpers

  @moduletag :capture_log

  setup do
    # Set a test API key to avoid the missing key error
    System.put_env("TMDB_API_KEY", "test_api_key_12345")

    # Avoid cross-test pollution: the router pipeline caches successful GET
    # responses in a shared ETS table, keyed by method:path:query_string.
    MetadataRelay.Cache.clear()

    on_exit(fn ->
      TMDBHelpers.clear_tmdb_adapter()
      System.delete_env("TMDB_API_KEY")
    end)

    :ok
  end

  # A verbatim TMDB `/3/collection/{id}` response body. mydia's
  # `Mydia.Metadata.Structs.Collection.from_api_response/1` parses this exact
  # shape, so the relay must forward it untouched.
  defp collection_fixture do
    %{
      "id" => 10,
      "name" => "Star Wars Collection",
      "overview" => "The Star Wars saga.",
      "poster_path" => "/collection-poster.jpg",
      "backdrop_path" => "/collection-backdrop.jpg",
      "parts" => [
        %{
          "id" => 11,
          "title" => "Star Wars",
          "original_title" => "Star Wars",
          "overview" => "A long time ago...",
          "release_date" => "1977-05-25",
          "poster_path" => "/part-11-poster.jpg",
          "backdrop_path" => "/part-11-backdrop.jpg",
          "vote_average" => 8.6
        },
        %{
          "id" => 1891,
          "title" => "The Empire Strikes Back",
          "original_title" => "The Empire Strikes Back",
          "overview" => "The Empire strikes back.",
          "release_date" => "1980-05-17",
          "poster_path" => "/part-1891-poster.jpg",
          "backdrop_path" => "/part-1891-backdrop.jpg",
          "vote_average" => 8.4
        }
      ]
    }
  end

  describe "get_collection/2" do
    test "retrieves a collection by ID" do
      TMDBHelpers.set_tmdb_adapter(
        TMDBHelpers.mock_adapter_with_routes(%{
          "/3/collection/10" => {200, collection_fixture()}
        })
      )

      assert {:ok, body} = Handler.get_collection("10", [])
      assert body["id"] == 10
      assert body["name"] == "Star Wars Collection"
    end

    test "forwards the language query param to TMDB" do
      test_pid = self()

      TMDBHelpers.set_tmdb_adapter(fn request ->
        send(test_pid, {:request_url, request.url})
        {request, Req.Response.new(status: 200, body: collection_fixture())}
      end)

      assert {:ok, _body} = Handler.get_collection("10", language: "fr-FR")

      assert_received {:request_url, url}

      assert URI.decode_query(url.query || "") == %{
               "language" => "fr-FR",
               "api_key" => "test_api_key_12345"
             }
    end

    test "returns the TMDB body unmodified, including nested parts" do
      fixture = collection_fixture()

      TMDBHelpers.set_tmdb_adapter(
        TMDBHelpers.mock_adapter_with_routes(%{
          "/3/collection/10" => {200, fixture}
        })
      )

      assert {:ok, body} = Handler.get_collection("10", [])

      # Regression guard: reshaping/wrapping the response would silently
      # yield an empty parts list on the mydia side.
      assert body == fixture
      assert length(body["parts"]) == 2
      assert Enum.map(body["parts"], & &1["id"]) == [11, 1891]
    end

    test "handles collection not found" do
      TMDBHelpers.set_tmdb_adapter(
        TMDBHelpers.mock_adapter_with_routes(%{
          "/3/collection/999999999" =>
            {404, %{"status_message" => "The resource could not be found."}}
        })
      )

      assert {:error, {:http_error, 404, %{"status_message" => _}}} =
               Handler.get_collection("999999999", [])
    end
  end

  describe "GET /tmdb/collections/:id" do
    test "dispatches to the handler and returns the TMDB body verbatim" do
      fixture = collection_fixture()

      TMDBHelpers.set_tmdb_adapter(
        TMDBHelpers.mock_adapter_with_routes(%{
          "/3/collection/10" => {200, fixture}
        })
      )

      conn =
        Plug.Test.conn(:get, "/tmdb/collections/10?language=en-US")
        |> Router.call([])

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)

      # Whole-body equality, not a field spot-check: anything the pipeline adds,
      # drops, or renames would hide the franchise on the mydia side rather than
      # fail, so a partial assertion is not enough to catch it.
      assert response == fixture
      assert length(response["parts"]) == 2
      assert Enum.map(response["parts"], & &1["id"]) == [11, 1891]
    end

    test "forwards the language query param through the route to TMDB" do
      test_pid = self()

      TMDBHelpers.set_tmdb_adapter(fn request ->
        send(test_pid, {:request_url, request.url})
        {request, Req.Response.new(status: 200, body: collection_fixture())}
      end)

      conn =
        Plug.Test.conn(:get, "/tmdb/collections/10?language=fr-FR")
        |> Router.call([])

      assert conn.status == 200
      assert_received {:request_url, url}
      assert URI.decode_query(url.query || "")["language"] == "fr-FR"
    end

    test "propagates a TMDB 404 with its status and error body" do
      error_body = %{
        "status_code" => 34,
        "status_message" => "The resource you requested could not be found."
      }

      TMDBHelpers.set_tmdb_adapter(
        TMDBHelpers.mock_adapter_with_routes(%{
          "/3/collection/999999999" => {404, error_body}
        })
      )

      conn =
        Plug.Test.conn(:get, "/tmdb/collections/999999999?language=en-US")
        |> Router.call([])

      # mydia turns this 404 into a silently absent section, so the status has to
      # survive the pipeline rather than being collapsed into a 500.
      assert conn.status == 404
      assert Jason.decode!(conn.resp_body) == error_body
    end
  end

  defp person_search_fixture do
    %{
      "page" => 1,
      "results" => [
        %{
          "id" => 31,
          "name" => "Ione Marsh",
          "known_for_department" => "Acting",
          "profile_path" => "/marsh.jpg",
          "popularity" => 12.5
        }
      ],
      "total_pages" => 1,
      "total_results" => 1
    }
  end

  defp person_fixture do
    %{
      "id" => 31,
      "name" => "Ione Marsh",
      "biography" => "An invented performer.",
      "birthday" => "1970-01-02",
      "profile_path" => "/marsh.jpg",
      "combined_credits" => %{
        "cast" => [%{"id" => 500, "media_type" => "movie", "title" => "Lantern Road"}],
        "crew" => []
      }
    }
  end

  describe "GET /tmdb/person/search" do
    test "dispatches to the handler and returns the TMDB body verbatim" do
      fixture = person_search_fixture()

      TMDBHelpers.set_tmdb_adapter(
        TMDBHelpers.mock_adapter_with_routes(%{
          "/3/search/person" => {200, fixture}
        })
      )

      conn =
        Plug.Test.conn(:get, "/tmdb/person/search?query=marsh")
        |> Router.call([])

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == fixture
    end

    test "forwards query, language, page and include_adult to TMDB" do
      test_pid = self()

      TMDBHelpers.set_tmdb_adapter(fn request ->
        send(test_pid, {:request_url, request.url})
        {request, Req.Response.new(status: 200, body: person_search_fixture())}
      end)

      conn =
        Plug.Test.conn(
          :get,
          "/tmdb/person/search?query=marsh&language=fr-FR&page=2&include_adult=false"
        )
        |> Router.call([])

      assert conn.status == 200
      assert_received {:request_url, url}
      assert url.path == "/3/search/person"
      query = URI.decode_query(url.query || "")
      assert query["query"] == "marsh"
      assert query["language"] == "fr-FR"
      assert query["page"] == "2"
      assert query["include_adult"] == "false"
    end

    test "propagates a TMDB error status" do
      error_body = %{"status_code" => 7, "status_message" => "Invalid API key"}

      TMDBHelpers.set_tmdb_adapter(
        TMDBHelpers.mock_adapter_with_routes(%{
          "/3/search/person" => {401, error_body}
        })
      )

      conn =
        Plug.Test.conn(:get, "/tmdb/person/search?query=marsh")
        |> Router.call([])

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == error_body
    end
  end

  describe "GET /tmdb/person/popular" do
    test "dispatches to the handler and returns the TMDB body verbatim" do
      fixture = person_search_fixture()

      TMDBHelpers.set_tmdb_adapter(
        TMDBHelpers.mock_adapter_with_routes(%{
          "/3/person/popular" => {200, fixture}
        })
      )

      conn =
        Plug.Test.conn(:get, "/tmdb/person/popular")
        |> Router.call([])

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == fixture
    end

    test "forwards language and page to TMDB" do
      test_pid = self()

      TMDBHelpers.set_tmdb_adapter(fn request ->
        send(test_pid, {:request_url, request.url})
        {request, Req.Response.new(status: 200, body: person_search_fixture())}
      end)

      conn =
        Plug.Test.conn(:get, "/tmdb/person/popular?language=fr-FR&page=3")
        |> Router.call([])

      assert conn.status == 200
      assert_received {:request_url, url}
      assert url.path == "/3/person/popular"
      query = URI.decode_query(url.query || "")
      assert query["language"] == "fr-FR"
      assert query["page"] == "3"
    end
  end

  describe "GET /tmdb/person/:id" do
    test "dispatches to the handler and returns the TMDB body verbatim" do
      fixture = person_fixture()

      TMDBHelpers.set_tmdb_adapter(
        TMDBHelpers.mock_adapter_with_routes(%{
          "/3/person/31" => {200, fixture}
        })
      )

      conn =
        Plug.Test.conn(:get, "/tmdb/person/31?language=en-US")
        |> Router.call([])

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == fixture
    end

    test "forwards language and append_to_response to TMDB" do
      test_pid = self()

      TMDBHelpers.set_tmdb_adapter(fn request ->
        send(test_pid, {:request_url, request.url})
        {request, Req.Response.new(status: 200, body: person_fixture())}
      end)

      conn =
        Plug.Test.conn(:get, "/tmdb/person/31?language=fr-FR&append_to_response=combined_credits")
        |> Router.call([])

      assert conn.status == 200
      assert_received {:request_url, url}
      assert url.path == "/3/person/31"
      query = URI.decode_query(url.query || "")
      assert query["language"] == "fr-FR"
      assert query["append_to_response"] == "combined_credits"
    end

    test "propagates a TMDB 404 with its status and error body" do
      error_body = %{
        "status_code" => 34,
        "status_message" => "The resource you requested could not be found."
      }

      TMDBHelpers.set_tmdb_adapter(
        TMDBHelpers.mock_adapter_with_routes(%{
          "/3/person/999999999" => {404, error_body}
        })
      )

      conn =
        Plug.Test.conn(:get, "/tmdb/person/999999999")
        |> Router.call([])

      assert conn.status == 404
      assert Jason.decode!(conn.resp_body) == error_body
    end
  end

  defp watch_providers_fixture do
    %{
      "results" => [
        %{
          "provider_id" => 8001,
          "provider_name" => "Maplestream",
          "logo_path" => "/maple.png",
          "display_priority" => 4,
          "display_priorities" => %{"CA" => 1}
        }
      ]
    }
  end

  describe "GET /tmdb/watch/providers/:type" do
    test "movie: forwards watch_region and returns the body verbatim" do
      test_pid = self()

      TMDBHelpers.set_tmdb_adapter(fn request ->
        send(test_pid, {:request_url, request.url})
        {request, Req.Response.new(status: 200, body: watch_providers_fixture())}
      end)

      conn =
        Plug.Test.conn(:get, "/tmdb/watch/providers/movie?watch_region=CA")
        |> Router.call([])

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == watch_providers_fixture()
      assert_received {:request_url, url}
      assert url.path == "/3/watch/providers/movie"
      assert URI.decode_query(url.query || "")["watch_region"] == "CA"
    end

    test "tv: forwards watch_region and returns the body verbatim" do
      test_pid = self()

      TMDBHelpers.set_tmdb_adapter(fn request ->
        send(test_pid, {:request_url, request.url})
        {request, Req.Response.new(status: 200, body: watch_providers_fixture())}
      end)

      conn =
        Plug.Test.conn(:get, "/tmdb/watch/providers/tv?watch_region=CA")
        |> Router.call([])

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == watch_providers_fixture()
      assert_received {:request_url, url}
      assert url.path == "/3/watch/providers/tv"
      assert URI.decode_query(url.query || "")["watch_region"] == "CA"
    end

    test "an unknown type is a 404 and never reaches TMDB" do
      TMDBHelpers.set_tmdb_adapter(fn _request -> flunk("TMDB must not be called") end)

      conn = Plug.Test.conn(:get, "/tmdb/watch/providers/music") |> Router.call([])

      assert conn.status == 404
    end
  end
end
