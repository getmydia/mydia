defmodule MydiaWeb.Api.MediaControllerTest do
  # Mutates the global :mydia, :metadata_relay_url application env to point
  # at a Bypass server, so this file cannot run concurrently with itself or
  # with anything else touching the same key.
  use MydiaWeb.ConnCase, async: false

  alias Mydia.Media

  setup do
    {user, token} = MydiaWeb.AuthHelpers.create_user_and_token()
    {:ok, movie} = create_media_item("movie")

    {:ok, user: user, token: token, movie: movie}
  end

  describe "POST /api/v1/media/:id/match" do
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

    # A numeric provider_id reaches the relay and the DB update commits --
    # proving the fix (Integer.parse feeding a real integer ref, rather than
    # the crash this finding is about). The endpoint cannot be asserted all
    # the way to a 200 here: `serialize_media_item/1` reads
    # `media_item.overview`, `.poster_url`, `.backdrop_url`, `.genres`,
    # `.runtime` and `.status`, none of which are fields on
    # `Mydia.Media.MediaItem` (metadata lives in the single `:metadata`
    # column instead). That is a pre-existing defect, unrelated to the
    # provider-ref work this branch is about and already present on
    # origin/master, so it is out of scope here -- but it means every
    # successful match 500s today. This test pins that down so a future fix
    # of the serializer is the thing that turns it green, rather than
    # silently dropping coverage of the numeric happy path.
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

      assert_raise KeyError, ~r/:overview/, fn ->
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/media/#{movie.id}/match", %{
          "provider_id" => to_string(tmdb_id),
          "provider_type" => "tmdb"
        })
      end

      updated = Media.get_media_item!(movie.id)
      assert updated.tmdb_id == tmdb_id
      assert updated.title == "Rebound Signal"
    end
  end

  # skip_episode_refresh: true keeps this at the controller's own validation
  # (provider_id parsing) rather than a real network-backed episode list, the
  # same reasoning test/mydia_web/controllers/api/playback_controller_test.exs
  # uses for its own create_media_item/1 helper.
  defp create_media_item(type) do
    Media.create_media_item(
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
