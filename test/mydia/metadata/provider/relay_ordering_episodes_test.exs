defmodule Mydia.Metadata.Provider.RelayOrderingEpisodesTest do
  use ExUnit.Case, async: true

  alias Mydia.Metadata.Provider.Relay

  defp config(bypass) do
    %{
      type: :metadata_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{language: "en-US", include_adult: false, timeout: 30_000}
    }
  end

  describe "fetch_raw_seasons/2" do
    test "returns the unfiltered seasons list, every ordering included" do
      bypass = Bypass.open()
      tvdb_id = System.unique_integer([:positive])

      Bypass.expect_once(bypass, "GET", "/tvdb/series/#{tvdb_id}/extended", fn conn ->
        json(conn, %{
          "data" => %{
            "seasons" => [
              %{"id" => 1, "number" => 1, "type" => %{"type" => "official"}},
              %{"id" => 2, "number" => 1, "type" => %{"type" => "dvd"}}
            ]
          }
        })
      end)

      assert {:ok, seasons} = Relay.fetch_raw_seasons(config(bypass), to_string(tvdb_id))
      assert length(seasons) == 2
      assert Enum.map(seasons, & &1["type"]["type"]) == ["official", "dvd"]
    end

    test "propagates a 404 as a not_found error, not a crash" do
      bypass = Bypass.open()
      tvdb_id = System.unique_integer([:positive])

      Bypass.expect_once(bypass, "GET", "/tvdb/series/#{tvdb_id}/extended", fn conn ->
        Plug.Conn.resp(conn, 404, "")
      end)

      assert {:error, _reason} = Relay.fetch_raw_seasons(config(bypass), to_string(tvdb_id))
    end
  end

  describe "fetch_ordering_episodes/4" do
    test "fetches only the requested ordering's seasons, one request each" do
      bypass = Bypass.open()
      tvdb_id = System.unique_integer([:positive])
      official_season_id = 100
      dvd_season_id = 200

      hits = start_supervised!({Agent, fn -> [] end})

      raw_seasons = [
        %{"id" => official_season_id, "number" => 1, "type" => %{"type" => "official"}},
        %{"id" => dvd_season_id, "number" => 1, "type" => %{"type" => "dvd"}}
      ]

      Bypass.stub(bypass, "GET", "/tvdb/seasons/#{official_season_id}/extended", fn conn ->
        Agent.update(hits, &[official_season_id | &1])

        json(conn, %{
          "data" => %{
            "id" => official_season_id,
            "number" => 1,
            "episodes" => [%{"id" => 11, "seasonNumber" => 1, "number" => 1}]
          }
        })
      end)

      Bypass.stub(bypass, "GET", "/tvdb/seasons/#{dvd_season_id}/extended", fn conn ->
        Agent.update(hits, &[dvd_season_id | &1])

        json(conn, %{
          "data" => %{
            "id" => dvd_season_id,
            "number" => 1,
            "episodes" => [%{"id" => 22, "seasonNumber" => 1, "number" => 1}]
          }
        })
      end)

      assert {:ok, episodes} =
               Relay.fetch_ordering_episodes(
                 config(bypass),
                 to_string(tvdb_id),
                 "dvd",
                 raw_seasons
               )

      assert episodes == [
               %{provider_episode_id: "22", season_number: 1, episode_number: 1}
             ]

      # The "official" season was never requested — only "dvd" was asked for.
      refute official_season_id in Agent.get(hits, & &1)
      assert dvd_season_id in Agent.get(hits, & &1)
    end

    test "returns an empty list, not an error, when the ordering has no seasons" do
      bypass = Bypass.open()

      assert {:ok, []} =
               Relay.fetch_ordering_episodes(config(bypass), "123", "absolute", [
                 %{"id" => 1, "number" => 1, "type" => %{"type" => "official"}}
               ])
    end

    test "rejects an episode record with no episode number instead of mapping it to nil" do
      bypass = Bypass.open()
      season_id = System.unique_integer([:positive])

      Bypass.stub(bypass, "GET", "/tvdb/seasons/#{season_id}/extended", fn conn ->
        json(conn, %{
          "data" => %{
            "id" => season_id,
            "number" => 1,
            "episodes" => [
              %{"id" => 1, "seasonNumber" => 1, "number" => 1},
              # TVDB sometimes lists a placeholder/movie-special entry with no
              # episode number. A nil "episode_number" here would happily
              # flow into a `SeasonOrder.remap/3` mapping as `{season, nil}`.
              %{"id" => 2, "seasonNumber" => 1, "number" => nil}
            ]
          }
        })
      end)

      raw_seasons = [%{"id" => season_id, "number" => 1, "type" => %{"type" => "official"}}]

      assert {:ok, episodes} =
               Relay.fetch_ordering_episodes(config(bypass), "123", "official", raw_seasons)

      assert episodes == [%{provider_episode_id: "1", season_number: 1, episode_number: 1}]
    end

    # A raised exception inside one season's fetch task must surface as
    # `{:error, _}`, not crash the caller. This runs synchronously inside a
    # LiveView `handle_event` (via `SeasonOrder.switch/3`), where an
    # unhandled `Task.async_stream` exit takes the whole LiveView process
    # down instead of reaching the generic `{:error, reason}` flash.
    test "a season fetch task crashing surfaces as an error, not a raised exception" do
      bypass = Bypass.open()
      season_id = System.unique_integer([:positive])

      Bypass.stub(bypass, "GET", "/tvdb/seasons/#{season_id}/extended", fn conn ->
        # `episodes` as a bare string (not a list, not null) makes the
        # season-parsing `Enum.reject/2`/`Enum.map/2` pipeline raise
        # `Protocol.UndefinedError` inside the async task, simulating a
        # malformed upstream response.
        json(conn, %{"data" => %{"id" => season_id, "number" => 1, "episodes" => "garbage"}})
      end)

      raw_seasons = [%{"id" => season_id, "number" => 1, "type" => %{"type" => "official"}}]

      assert {:error, _reason} =
               Relay.fetch_ordering_episodes(config(bypass), "123", "official", raw_seasons)
    end
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end
end
