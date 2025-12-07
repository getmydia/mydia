defmodule MydiaWeb.Api.MediaControllerTest do
  use MydiaWeb.ConnCase, async: true

  alias Mydia.Media

  setup do
    {user, token} = create_user_and_token()
    {admin_user, admin_token} = create_user_and_token(%{role: "admin"})
    # Guest users cannot update media
    {guest_user, guest_token} = create_user_and_token(%{role: "guest"})

    {:ok, movie} = create_movie()
    {:ok, tv_show} = create_tv_show()

    {:ok,
     user: user,
     token: token,
     admin_user: admin_user,
     admin_token: admin_token,
     guest_user: guest_user,
     guest_token: guest_token,
     movie: movie,
     tv_show: tv_show}
  end

  describe "GET /api/v1/media/:id" do
    test "returns movie details", %{conn: conn, token: token, movie: movie} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/media/#{movie.id}")

      response = json_response(conn, 200)
      assert response["data"]["id"] == movie.id
      assert response["data"]["title"] == movie.title
      assert response["data"]["type"] == "movie"
      assert response["data"]["year"] == movie.year
    end

    test "returns tv show details with episodes", %{conn: conn, token: token, tv_show: tv_show} do
      # Create some episodes
      {:ok, _ep1} =
        Media.create_episode(%{
          media_item_id: tv_show.id,
          season_number: 1,
          episode_number: 1,
          title: "Pilot"
        })

      {:ok, _ep2} =
        Media.create_episode(%{
          media_item_id: tv_show.id,
          season_number: 1,
          episode_number: 2,
          title: "Second Episode"
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/media/#{tv_show.id}")

      response = json_response(conn, 200)
      assert response["data"]["id"] == tv_show.id
      assert response["data"]["type"] == "tv_show"
      assert is_list(response["data"]["episodes"])
      assert length(response["data"]["episodes"]) == 2
    end

    test "returns 404 for non-existent media item", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/media/00000000-0000-0000-0000-000000000000")

      assert json_response(conn, 404)["error"] == "Media item not found"
    end

    test "requires authentication", %{conn: conn, movie: movie} do
      conn = get(conn, "/api/v1/media/#{movie.id}")

      # Should get 401 Unauthorized or redirect
      assert conn.status in [401, 302]
    end
  end

  describe "POST /api/v1/media/:id/match" do
    test "returns 400 when provider_id is missing", %{
      conn: conn,
      admin_token: admin_token,
      movie: movie
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{admin_token}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/media/#{movie.id}/match", %{})

      assert json_response(conn, 400)["error"] == "provider_id is required"
    end

    test "returns 400 when provider_id is empty", %{
      conn: conn,
      admin_token: admin_token,
      movie: movie
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{admin_token}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/media/#{movie.id}/match", %{provider_id: ""})

      assert json_response(conn, 400)["error"] == "provider_id is required"
    end

    test "returns 400 for invalid provider_type", %{
      conn: conn,
      admin_token: admin_token,
      movie: movie
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{admin_token}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/media/#{movie.id}/match", %{
          provider_id: "12345",
          provider_type: "invalid"
        })

      assert json_response(conn, 400)["error"] ==
               "invalid provider_type, must be 'tmdb' or 'tvdb'"
    end

    test "returns 404 for non-existent media item", %{conn: conn, admin_token: admin_token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{admin_token}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/media/00000000-0000-0000-0000-000000000000/match", %{
          provider_id: "12345"
        })

      assert json_response(conn, 404)["error"] == "Media item not found"
    end

    test "returns 403 for guest users without update permission", %{
      conn: conn,
      guest_token: guest_token,
      movie: movie
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{guest_token}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/media/#{movie.id}/match", %{provider_id: "12345"})

      assert json_response(conn, 403)["error"] ==
               "You do not have permission to modify media items"
    end

    test "requires authentication", %{conn: conn, movie: movie} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/media/#{movie.id}/match", %{provider_id: "12345"})

      # Should get 401 Unauthorized or redirect
      assert conn.status in [401, 302]
    end
  end

  # Helper functions
  defp create_movie do
    Media.create_media_item(%{
      title: "Test Movie #{System.unique_integer([:positive])}",
      tmdb_id: System.unique_integer([:positive]),
      type: "movie",
      year: 2024,
      monitored: true
    })
  end

  defp create_tv_show do
    Media.create_media_item(%{
      title: "Test TV Show #{System.unique_integer([:positive])}",
      tmdb_id: System.unique_integer([:positive]),
      type: "tv_show",
      monitored: true
    })
  end
end
