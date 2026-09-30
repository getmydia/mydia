defmodule Mydia.Metadata.Provider.RelayDiscoverTest do
  use ExUnit.Case, async: true

  alias Mydia.Metadata.Provider.Relay

  setup do
    bypass = Bypass.open()

    config = %{
      type: :metadata_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{language: "en-US", include_adult: false}
    }

    %{bypass: bypass, config: config}
  end

  defp capture_query(bypass, path) do
    test_pid = self()

    Bypass.expect_once(bypass, "GET", path, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:query, conn.query_params})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"results" => [], "total_pages" => 1}))
    end)
  end

  for {media_type, path} <- [movie: "/tmdb/movies/discover", tv_show: "/tmdb/tv/discover"] do
    test "#{media_type}: never sends with_origin_country",
         %{bypass: bypass, config: config} do
      capture_query(bypass, unquote(path))

      assert {:ok, _} = Relay.fetch_discover(config, unquote(media_type), origin_country: "CA")
      assert_receive {:query, params}
      refute Map.has_key?(params, "with_origin_country")
    end

    test "#{media_type}: sends the streaming params when given", %{bypass: bypass, config: config} do
      capture_query(bypass, unquote(path))

      assert {:ok, _} =
               Relay.fetch_discover(config, unquote(media_type),
                 watch_region: "CA",
                 with_watch_providers: "8001",
                 with_watch_monetization_types: "flatrate",
                 min_votes: 10
               )

      assert_receive {:query, params}
      assert params["watch_region"] == "CA"
      assert params["with_watch_providers"] == "8001"
      assert params["with_watch_monetization_types"] == "flatrate"
      assert params["vote_count.gte"] == "10"
    end

    test "#{media_type}: omits the new params otherwise", %{bypass: bypass, config: config} do
      capture_query(bypass, unquote(path))

      assert {:ok, _} = Relay.fetch_discover(config, unquote(media_type), [])
      assert_receive {:query, params}

      for key <-
            ~w(region watch_region with_watch_providers with_watch_monetization_types with_release_type vote_count.gte release_date.gte primary_release_date.gte first_air_date.gte) do
        refute Map.has_key?(params, key), "unexpected #{key}"
      end
    end
  end

  describe "release date bounds" do
    test "movie with a region filters on the regional release date", %{
      bypass: bypass,
      config: config
    } do
      capture_query(bypass, "/tmdb/movies/discover")

      Relay.fetch_discover(config, :movie,
        region: "CA",
        with_release_type: "2|3",
        release_date_gte: "2026-08-18",
        release_date_lte: "2026-09-29"
      )

      assert_receive {:query, params}
      assert params["region"] == "CA"
      assert params["with_release_type"] == "2|3"
      assert params["release_date.gte"] == "2026-08-18"
      assert params["release_date.lte"] == "2026-09-29"
      refute Map.has_key?(params, "primary_release_date.gte")
    end

    test "movie without a region filters on the primary release date", %{
      bypass: bypass,
      config: config
    } do
      capture_query(bypass, "/tmdb/movies/discover")

      Relay.fetch_discover(config, :movie, release_date_lte: "2026-09-29")

      assert_receive {:query, params}
      assert params["primary_release_date.lte"] == "2026-09-29"
      refute Map.has_key?(params, "release_date.lte")
    end

    test "tv filters on the first air date", %{bypass: bypass, config: config} do
      capture_query(bypass, "/tmdb/tv/discover")

      Relay.fetch_discover(config, :tv_show, release_date_lte: "2026-09-29")

      assert_receive {:query, params}
      assert params["first_air_date.lte"] == "2026-09-29"
    end
  end

  describe "fetch_watch_providers/3" do
    test "parses and sorts by the region's display priority", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "GET", "/tmdb/watch/providers/movie", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["watch_region"] == "CA"

        body = %{
          "results" => [
            %{
              "provider_id" => 2,
              "provider_name" => "Northflix",
              "logo_path" => "/n.png",
              "display_priority" => 1,
              "display_priorities" => %{"CA" => 5}
            },
            %{
              "provider_id" => 1,
              "provider_name" => "Maplestream",
              "logo_path" => "/m.png",
              "display_priority" => 9,
              "display_priorities" => %{"CA" => 0}
            }
          ]
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      assert {:ok, [first, second]} = Relay.fetch_watch_providers(config, :movie, "CA")
      assert first.name == "Maplestream"
      assert first.id == 1
      assert second.name == "Northflix"
    end

    test "tv uses the tv route", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "GET", "/tmdb/watch/providers/tv", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"results" => []}))
      end)

      assert {:ok, []} = Relay.fetch_watch_providers(config, :tv_show, "CA")
    end

    test "a non-200 is an error", %{bypass: bypass, config: config} do
      Bypass.stub(bypass, "GET", "/tmdb/watch/providers/movie", fn conn ->
        Plug.Conn.resp(conn, 500, "{}")
      end)

      assert {:error, _} = Relay.fetch_watch_providers(config, :movie, "CA")
    end
  end
end
