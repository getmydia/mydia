defmodule Mydia.Metadata.Provider.RelayTvdbVideosTest do
  @moduledoc """
  Offline coverage for the three-tier trailer resolution on the TVDB fetch path.

  Deliberately NOT tagged `:external` — `test/test_helper.exs` excludes that tag,
  and the tier logic (provider data shapes, the TMDB cross-reference fallback,
  and the "a missing trailer must never fail the fetch" degrade path) has to run
  in CI. Both relay endpoints are stubbed with Bypass.
  """

  use ExUnit.Case, async: true

  alias Mydia.Metadata.Provider.Relay
  alias Mydia.Metadata.Structs.Video

  setup do
    bypass = Bypass.open()

    config = %{
      type: :metadata_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{
        language: "en-US",
        include_adult: false,
        # Keep the fast-degrade paths fast: the fixture server is local.
        timeout: 2_000,
        connect_timeout: 1_000
      }
    }

    # Offset well past any real provider id so the process-global
    # Mydia.Metadata.Cache and Mydia.Metadata.ProviderIDRegistry entries these
    # tests create can never collide with another test file's ids.
    tvdb_id = to_string(900_000_000 + System.unique_integer([:positive]))
    tmdb_id = to_string(900_000_000 + System.unique_integer([:positive]))

    {:ok, bypass: bypass, config: config, tvdb_id: tvdb_id, tmdb_id: tmdb_id}
  end

  describe "tier 1: TVDB's own trailers" do
    test "uses TVDB trailers and never requests TMDB", ctx do
      stub_tvdb(ctx, %{
        "trailers" => [tvdb_trailer("https://www.youtube.com/watch?v=TVDBKEY1")],
        "remoteIds" => [tmdb_remote_id(ctx.tmdb_id)]
      })

      stub_tmdb(ctx, [tmdb_video("TMDBKEY1")])

      assert {:ok, metadata} =
               Relay.fetch_by_id(ctx.config, ctx.tvdb_id, media_type: :tv_show, provider: :tvdb)

      assert metadata.provider == :tvdb
      assert [%Video{} = video] = metadata.videos
      assert video.key == "TVDBKEY1"
      assert video.site == "YouTube"
      assert video.type == "Trailer"

      # Tier 1 short-circuits: the cross-reference exists but must not be used.
      refute_receive {:relay_request, :tmdb}, 100
    end
  end

  describe "tier 2: TMDB cross-reference fallback" do
    test "uses TMDB videos when TVDB carries no trailers", ctx do
      stub_tvdb(ctx, %{
        "trailers" => [],
        "remoteIds" => [tmdb_remote_id(ctx.tmdb_id)]
      })

      stub_tmdb(ctx, [tmdb_video("TMDBKEY1")])

      assert {:ok, metadata} =
               Relay.fetch_by_id(ctx.config, ctx.tvdb_id, media_type: :tv_show, provider: :tvdb)

      assert metadata.provider == :tvdb
      assert [%Video{} = video] = metadata.videos
      assert video.key == "TMDBKEY1"
      assert video.site == "YouTube"

      assert_receive {:relay_request, :tmdb}, 100
    end

    test "memoizes the fallback so repeat fetches cost one TMDB request", ctx do
      stub_tvdb(ctx, %{
        "trailers" => [],
        "remoteIds" => [tmdb_remote_id(ctx.tmdb_id)]
      })

      stub_tmdb(ctx, [tmdb_video("TMDBKEY1")])

      for _ <- 1..3 do
        assert {:ok, metadata} =
                 Relay.fetch_by_id(ctx.config, ctx.tvdb_id, media_type: :tv_show, provider: :tvdb)

        assert [%Video{key: "TMDBKEY1"}] = metadata.videos
      end

      assert_receive {:relay_request, :tmdb}, 100
      refute_receive {:relay_request, :tmdb}, 100
    end

    test "caches an empty result so a show with no trailers anywhere stops re-requesting", ctx do
      stub_tvdb(ctx, %{
        "trailers" => [],
        "remoteIds" => [tmdb_remote_id(ctx.tmdb_id)]
      })

      stub_tmdb(ctx, [])

      for _ <- 1..3 do
        assert {:ok, metadata} =
                 Relay.fetch_by_id(ctx.config, ctx.tvdb_id, media_type: :tv_show, provider: :tvdb)

        assert metadata.videos == []
      end

      assert_receive {:relay_request, :tmdb}, 100
      refute_receive {:relay_request, :tmdb}, 100
    end
  end

  describe "tier 3: degrade to no videos" do
    test "returns an empty list when there is no TMDB cross-reference", ctx do
      stub_tvdb(ctx, %{"trailers" => [], "remoteIds" => []})
      stub_tmdb(ctx, [tmdb_video("TMDBKEY1")])

      assert {:ok, metadata} =
               Relay.fetch_by_id(ctx.config, ctx.tvdb_id, media_type: :tv_show, provider: :tvdb)

      assert metadata.provider == :tvdb
      assert metadata.videos == []
      assert metadata.title == "Fixture Show"

      refute_receive {:relay_request, :tmdb}, 100
    end

    test "ignores a non-string TMDB id in remoteIds rather than raising", ctx do
      # An integer id would reach ProviderIDRegistry.record_id_type/3, whose
      # is_binary/1 guard would raise FunctionClauseError inside the fetch.
      stub_tvdb(ctx, %{
        "trailers" => [],
        "remoteIds" => [%{"sourceName" => "TheMovieDB.com", "id" => 1399, "type" => 12}]
      })

      stub_tmdb(ctx, [tmdb_video("TMDBKEY1")])

      assert {:ok, metadata} =
               Relay.fetch_by_id(ctx.config, ctx.tvdb_id, media_type: :tv_show, provider: :tvdb)

      assert metadata.videos == []
      refute_receive {:relay_request, :tmdb}, 100
    end

    test "still returns {:ok, metadata} when the TMDB fallback request fails", ctx do
      stub_tvdb(ctx, %{
        "trailers" => [],
        "remoteIds" => [tmdb_remote_id(ctx.tmdb_id)]
      })

      test_pid = self()

      Bypass.expect(ctx.bypass, "GET", tmdb_path(ctx), fn conn ->
        send(test_pid, {:relay_request, :tmdb})
        Plug.Conn.resp(conn, 500, "boom")
      end)

      # Req treats 5xx as transient and retries, which logs warnings; swallow
      # them so the suite output stays readable.
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, metadata} =
                 Relay.fetch_by_id(ctx.config, ctx.tvdb_id,
                   media_type: :tv_show,
                   provider: :tvdb
                 )

        # The binding constraint: a missing trailer never fails the fetch.
        assert metadata.provider == :tvdb
        assert metadata.videos == []
        assert metadata.title == "Fixture Show"
      end)

      assert_receive {:relay_request, :tmdb}, 100
    end
  end

  ## Fixtures

  defp tmdb_path(ctx), do: "/tmdb/tv/shows/#{ctx.tmdb_id}"

  defp stub_tvdb(ctx, overrides) do
    test_pid = self()
    body = tvdb_extended(ctx.tvdb_id, overrides)

    Bypass.expect(ctx.bypass, "GET", "/tvdb/series/#{ctx.tvdb_id}/extended", fn conn ->
      send(test_pid, {:relay_request, :tvdb})
      json(conn, 200, body)
    end)
  end

  defp stub_tmdb(ctx, videos) do
    test_pid = self()
    body = tmdb_tv_show(ctx.tmdb_id, videos)

    Bypass.stub(ctx.bypass, "GET", tmdb_path(ctx), fn conn ->
      send(test_pid, {:relay_request, :tmdb})
      json(conn, 200, body)
    end)
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  # Mirrors the real /tvdb/series/{id}/extended shape: everything nests under
  # "data", and the fields below are the ones transform_tvdb_to_tmdb_format/3
  # and parse_metadata/3 read.
  defp tvdb_extended(tvdb_id, overrides) do
    data =
      Map.merge(
        %{
          "id" => String.to_integer(tvdb_id),
          "name" => "Fixture Show",
          "overview" => "A show used to exercise trailer resolution.",
          "firstAired" => "2016-07-15",
          "lastAired" => "2019-07-04",
          "status" => %{"name" => "Continuing"},
          "originalLanguage" => "eng",
          "originalCountry" => "usa",
          "image" => "https://artworks.thetvdb.com/banners/posters/fixture.jpg",
          "artworks" => [
            %{
              "type" => 3,
              "image" => "https://artworks.thetvdb.com/banners/backgrounds/fixture.jpg"
            }
          ],
          "genres" => [%{"id" => 18, "name" => "Drama"}],
          "seasons" => [
            %{
              "id" => 1_001,
              "number" => 1,
              "name" => "Season 1",
              "type" => %{"type" => "official"},
              "episodeCount" => 8
            }
          ],
          "translations" => %{"nameTranslations" => [], "overviewTranslations" => []},
          "remoteIds" => [],
          "trailers" => []
        },
        overrides
      )

    %{"data" => data}
  end

  defp tvdb_trailer(url) do
    %{"id" => 204_863, "language" => "eng", "name" => "Trailer", "runtime" => 0, "url" => url}
  end

  defp tmdb_remote_id(tmdb_id) do
    %{"id" => tmdb_id, "type" => 12, "sourceName" => "TheMovieDB.com"}
  end

  defp tmdb_tv_show(tmdb_id, videos) do
    %{
      "id" => String.to_integer(tmdb_id),
      "name" => "Fixture Show",
      "overview" => "A show used to exercise trailer resolution.",
      "first_air_date" => "2016-07-15",
      "genres" => [%{"id" => 18, "name" => "Drama"}],
      "videos" => %{"results" => videos}
    }
  end

  defp tmdb_video(key) do
    %{
      "id" => "5f0#{key}",
      "key" => key,
      "name" => "Official Trailer",
      "site" => "YouTube",
      "type" => "Trailer",
      "official" => true,
      "published_at" => "2019-07-01T14:00:00.000Z"
    }
  end
end
