defmodule Mydia.WatchSync.Providers.JellyfinTest do
  use ExUnit.Case, async: true

  alias Mydia.WatchSync.Providers.Jellyfin

  setup do
    bypass = Bypass.open()

    config = %Mydia.Settings.MediaServerConfig{
      name: "Jellyfin",
      type: :jellyfin,
      url: "http://localhost:#{bypass.port}",
      token: "api-key"
    }

    {:ok,
     bypass: bypass,
     config: config,
     scope: %{user_id: "u1", remote_user_id: "jf1", access_token: nil}}
  end

  defp items_response(items) do
    Jason.encode!(%{"Items" => items, "TotalRecordCount" => length(items)})
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, body)
  end

  describe "refresh_mappings/2" do
    test "maps movies and episodes with provider ids", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "GET", "/Items", fn conn ->
        json(
          conn,
          200,
          items_response([
            %{"Id" => "m1", "Type" => "Movie", "ProviderIds" => %{"Tmdb" => "603"}},
            %{
              "Id" => "e1",
              "Type" => "Episode",
              "ParentIndexNumber" => 2,
              "IndexNumber" => 5,
              "ProviderIds" => %{"Tvdb" => "12345"}
            }
          ])
        )
      end)

      assert {:ok, [movie, episode]} = Jellyfin.refresh_mappings(config, [])

      assert movie == %{
               remote_id: "m1",
               external_ids: %{tmdb: "603"},
               season_number: nil,
               episode_number: nil,
               type: :movie
             }

      assert episode.type == :episode
      assert episode.season_number == 2
      assert episode.episode_number == 5
      assert episode.external_ids == %{tvdb: "12345"}
    end

    test "maps lowercase provider id keys and drops unknown ones", %{
      bypass: bypass,
      config: config
    } do
      Bypass.expect_once(bypass, "GET", "/Items", fn conn ->
        json(
          conn,
          200,
          items_response([
            %{
              "Id" => "m1",
              "Type" => "Movie",
              "ProviderIds" => %{"tmdb" => "603", "Imdb" => "tt0137523", "Anidb" => "999"}
            }
          ])
        )
      end)

      assert {:ok, [movie]} = Jellyfin.refresh_mappings(config, [])
      assert movie.external_ids == %{tmdb: "603", imdb: "tt0137523"}
    end
  end

  describe "list_changes/3" do
    test "reads watch state, converts ticks to seconds, and scopes the request to the user", %{
      bypass: bypass,
      config: config,
      scope: scope
    } do
      Bypass.expect_once(bypass, "GET", "/Items", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["userId"] == "jf1"

        json(
          conn,
          200,
          items_response([
            %{
              "Id" => "m1",
              "Type" => "Movie",
              "UserData" => %{
                "Played" => true,
                "PlaybackPositionTicks" => 90_000_000_000,
                "LastPlayedDate" => "2026-08-12T10:00:00.0000000Z"
              }
            }
          ])
        )
      end)

      assert {:ok, [state]} = Jellyfin.list_changes(config, scope, nil)
      assert state.remote_id == "m1"
      assert state.watched == true
      assert state.position_seconds == 9000
      # Confirms the seven-fractional-digit format Jellyfin sends parses
      # cleanly and truncates to Elixir's microsecond (6-digit) precision.
      assert state.at == ~U[2026-08-12 10:00:00.000000Z]
    end

    test "drops items last played before the cursor", %{
      bypass: bypass,
      config: config,
      scope: scope
    } do
      Bypass.expect_once(bypass, "GET", "/Items", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["userId"] == "jf1"

        json(
          conn,
          200,
          items_response([
            %{
              "Id" => "old",
              "Type" => "Movie",
              "UserData" => %{
                "Played" => true,
                "LastPlayedDate" => "2026-08-01T00:00:00.0000000Z"
              }
            },
            %{
              "Id" => "new",
              "Type" => "Movie",
              "UserData" => %{
                "Played" => true,
                "LastPlayedDate" => "2026-08-12T00:00:00.0000000Z"
              }
            }
          ])
        )
      end)

      since = ~U[2026-08-10 00:00:00Z]

      assert {:ok, [state]} = Jellyfin.list_changes(config, scope, since)
      assert state.remote_id == "new"
    end

    test "treats a missing UserData block as unwatched", %{
      bypass: bypass,
      config: config,
      scope: scope
    } do
      Bypass.expect_once(bypass, "GET", "/Items", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["userId"] == "jf1"

        json(conn, 200, items_response([%{"Id" => "m1", "Type" => "Movie"}]))
      end)

      assert {:ok, [state]} = Jellyfin.list_changes(config, scope, nil)
      assert state.watched == false
      assert state.position_seconds == nil
    end

    # Regression guard: Jellyfin's UpdatePlayState never stamps LastPlayedDate
    # (and MarkUnplayed explicitly nulls it), so a nil date on an incremental
    # run must not be treated as "unchanged" when the item actually carries
    # watched state or a resume position. This must fail against a bare
    # `changed_since?(%{at: nil}, _), do: false` clause.
    test "includes a played item with no LastPlayedDate even on an incremental run", %{
      bypass: bypass,
      config: config,
      scope: scope
    } do
      Bypass.expect_once(bypass, "GET", "/Items", fn conn ->
        json(
          conn,
          200,
          items_response([
            %{"Id" => "no-date", "Type" => "Movie", "UserData" => %{"Played" => true}}
          ])
        )
      end)

      since = ~U[2026-08-10 00:00:00Z]

      assert {:ok, [state]} = Jellyfin.list_changes(config, scope, since)
      assert state.remote_id == "no-date"
      assert state.watched == true
    end

    test "errors when the scope carries no remote user id", %{config: config} do
      scope = %{user_id: "u1", remote_user_id: nil, access_token: nil}

      assert {:error, :missing_remote_user_id} = Jellyfin.list_changes(config, scope, nil)
    end
  end

  describe "apply_change/4" do
    test "marks played then writes position, scoped to the user", %{
      bypass: bypass,
      config: config,
      scope: scope
    } do
      Bypass.expect_once(bypass, "POST", "/UserPlayedItems/m1", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["userId"] == "jf1"
        json(conn, 200, "{}")
      end)

      Bypass.expect_once(bypass, "POST", "/UserItems/m1/UserData", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["userId"] == "jf1"
        json(conn, 200, "{}")
      end)

      assert :ok =
               Jellyfin.apply_change(config, scope, "m1", %{watched: true, position_seconds: 30})
    end

    test "errors when the scope carries no remote user id", %{config: config} do
      scope = %{user_id: "u1", remote_user_id: nil, access_token: nil}

      assert {:error, :missing_remote_user_id} =
               Jellyfin.apply_change(config, scope, "m1", %{watched: true, position_seconds: nil})
    end
  end
end
