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
end
