defmodule MydiaWeb.Api.MediaControllerTest do
  @moduledoc """
  `perform_manual_match/5` used to fold every `Media.update_media_item/4`
  error into `json(%{error: "Failed to update media item: \#{inspect(reason)}"})`,
  which is harmless for an `Ecto.Changeset` but literally returned the string
  ":restricted" once the update could fail that way -- an internal atom
  leaking straight into the API response body.
  """

  # Mutates the global :mydia, :metadata_relay_url application env to point
  # at a Bypass server, so this file cannot run concurrently with itself or
  # with anything else touching the same key.
  use MydiaWeb.ConnCase, async: false

  import Mydia.AccountsFixtures

  alias Mydia.Accounts.Scope
  alias Mydia.Media
  alias Mydia.Metadata.Provider
  alias Mydia.Metadata.Structs.{ImagesResponse, MediaMetadata}

  # media_controller.ex's extract_year/1 reads metadata.release_date.year, so
  # unlike most other test doubles in this suite it needs a real %Date{}
  # rather than the ISO string most providers store on the struct.
  defmodule LiveActionProvider do
    @behaviour Mydia.Metadata.Provider

    @impl true
    def test_connection(_config), do: {:ok, %{status: "ok"}}

    @impl true
    def search(_config, _query, _opts), do: {:ok, []}

    @impl true
    def fetch_by_id(_config, id, _opts) do
      {:ok,
       %MediaMetadata{
         provider_id: id,
         provider: :metadata_relay,
         media_type: :movie,
         id: String.to_integer(id),
         title: "Live Action Rematch",
         release_date: ~D[2015-06-01],
         genres: ["Action"]
       }}
    end

    @impl true
    def fetch_images(_config, _id, _opts),
      do: {:ok, ImagesResponse.new(%{posters: [], backdrops: [], logos: []})}

    @impl true
    def fetch_season(_config, _id, _season, _opts), do: {:ok, %{}}

    @impl true
    def fetch_trending(_config, _opts), do: {:ok, []}
  end

  describe "POST /api/v1/media/:id/match" do
    setup do
      {user, token} = MydiaWeb.AuthHelpers.create_user_and_token()
      {:ok, movie} = create_media_item("movie")

      {:ok, user: user, token: token, movie: movie}
    end

    test "returns 400 instead of crashing when provider_id is not numeric", %{
      conn: conn,
      token: token,
      movie: movie
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/media/#{movie.id}/match", %{
          "provider_id" => "not-a-number",
          "provider_type" => "tmdb"
        })

      assert json_response(conn, 400)["error"] =~ "provider_id"
    end

    # A JSON body can send provider_id as a bare number rather than a string
    # (`"provider_id": 0`). ConnTest's params map models that the same way a
    # real JSON parser would: an integer, not a binary. Integer.parse/1 only
    # accepts a binary and raises FunctionClauseError on ANY integer, which
    # would take the request down with a 500 instead of the documented 400.
    # 0 (rather than a real-looking id like 603) keeps this test from hitting
    # the network: it is rejected before any provider fetch is attempted, the
    # same way the non-numeric-string case above never reaches the relay.
    test "returns 400 instead of crashing when provider_id is a JSON number", %{
      conn: conn,
      token: token,
      movie: movie
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/media/#{movie.id}/match", %{
          "provider_id" => 0,
          "provider_type" => "tmdb"
        })

      assert json_response(conn, 400)["error"] =~ "provider_id"
    end

    # A numeric provider_id reaches the relay, the DB update commits, and the
    # response serializes. The serializer used to read `media_item.overview`,
    # `.poster_url`, `.backdrop_url`, `.genres`, `.runtime` and `.status`
    # straight off `%MediaItem{}`, where none of them are fields (metadata
    # lives in the single `:metadata` column), so every successful match
    # raised KeyError. That is fixed here, so this asserts the 200 rather
    # than pinning the crash.
    test "reaches the relay and updates the row on a numeric provider_id", %{
      conn: conn,
      token: token,
      movie: movie
    } do
      bypass = Bypass.open()
      previous_url = Application.get_env(:mydia, :metadata_relay_url)
      Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

      on_exit(fn ->
        case previous_url do
          nil -> Application.delete_env(:mydia, :metadata_relay_url)
          value -> Application.put_env(:mydia, :metadata_relay_url, value)
        end
      end)

      tmdb_id = System.unique_integer([:positive])

      body = %{
        "id" => tmdb_id,
        "title" => "Rebound Signal",
        "release_date" => "2022-05-01",
        "overview" => "x",
        "credits" => %{"cast" => [], "crew" => []},
        "genres" => []
      }

      Bypass.expect_once(bypass, "GET", "/tmdb/movies/#{tmdb_id}", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/media/#{movie.id}/match", %{
          "provider_id" => to_string(tmdb_id),
          "provider_type" => "tmdb"
        })

      assert json_response(conn, 200)

      updated = Media.get_media_item!(Scope.unrestricted(), movie.id)
      assert updated.tmdb_id == tmdb_id
      assert updated.title == "Rebound Signal"
    end
  end

  describe "POST /api/v1/media/:id/match under a restricted scope" do
    setup do
      Provider.Registry.register(:metadata_relay, LiveActionProvider)
      on_exit(fn -> Mydia.Metadata.register_providers() end)
      :ok
    end

    test "manually matching a restricted title returns a friendly message, not a raw atom",
         %{conn: conn} do
      movie = cartoon_movie()

      restricted =
        restricted_user_fixture(%{role: "user", allowed_categories: ["cartoon_movie"]})

      conn =
        conn
        |> log_in_user(restricted)
        |> post(~p"/api/v1/media/#{movie.id}/match", %{
          "provider_id" => "12345",
          "provider_type" => "tmdb"
        })

      assert %{"error" => message} = json_response(conn, 403)
      assert message == Media.restricted_message()
      refute message =~ ":restricted"

      # The stored item is untouched -- still the animated original, not the
      # live-action match that was refused.
      unchanged = Media.get_media_item!(Scope.unrestricted(), movie.id)
      assert unchanged.category == "cartoon_movie"
    end
  end

  defp cartoon_movie do
    {:ok, item} =
      Media.create_media_item(
        Scope.system(),
        %{
          type: "movie",
          title: "Cartoon Original",
          year: 2020,
          tmdb_id: System.unique_integer([:positive]),
          metadata: %MediaMetadata{
            provider_id: "9001",
            provider: :tmdb,
            media_type: :movie,
            genres: ["Animation"]
          }
        },
        skip_episode_refresh: true
      )

    assert item.category == "cartoon_movie"
    item
  end

  # skip_episode_refresh: true keeps this at the controller's own validation
  # (provider_id parsing) rather than a real network-backed episode list, the
  # same reasoning test/mydia_web/controllers/api/playback_controller_test.exs
  # uses for its own create_media_item/1 helper.
  defp create_media_item(type) do
    Media.create_media_item(
      Scope.system(),
      %{
        title: "Test #{type} #{System.unique_integer([:positive])}",
        tmdb_id: System.unique_integer([:positive]),
        type: type,
        year: 2024,
        monitored: true
      },
      skip_episode_refresh: true
    )
  end
end
