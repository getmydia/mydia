defmodule Mydia.Media.RecommendationsTest do
  @moduledoc """
  Covers the collapse of every provider outcome into `{:ok, results}` or `:none`,
  which is the whole reason this module exists: the two LiveViews that render the
  rail should have exactly one thing to check.
  """

  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures
  import ExUnit.CaptureLog

  alias Mydia.Media.{MediaItem, Recommendations}
  alias Mydia.Metadata.Cache

  setup do
    bypass = Bypass.open()

    config = %{
      type: :metadata_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{language: "en-US", include_adult: false, timeout: 2_000}
    }

    tmdb_id = 900_000_000 + System.unique_integer([:positive])

    on_exit(fn ->
      for media_type <- [:movie, :tv_show] do
        Cache.delete("recommendations:metadata_relay:#{tmdb_id}:#{media_type}:en-US")
      end
    end)

    %{bypass: bypass, config: config, tmdb_id: tmdb_id}
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  defp stub_recommendations(bypass, tmdb_id, results) do
    Bypass.stub(bypass, "GET", "/tmdb/movies/#{tmdb_id}", fn conn ->
      json(conn, 200, %{
        "id" => tmdb_id,
        "title" => "Source Movie",
        "recommendations" => %{
          "page" => 1,
          "results" => results,
          "total_pages" => 1,
          "total_results" => length(results)
        }
      })
    end)
  end

  describe "for_media_item/2" do
    test "returns parsed recommendations for a movie", %{
      bypass: bypass,
      config: config,
      tmdb_id: tmdb_id
    } do
      stub_recommendations(bypass, tmdb_id, [
        %{"id" => 101, "title" => "The Eternal Daughter", "release_date" => "2022-12-02"}
      ])

      item = media_item_fixture(%{type: "movie", title: "Aftersun", tmdb_id: tmdb_id})

      assert {:ok, [first]} = Recommendations.for_media_item(item, config)
      assert first.title == "The Eternal Daughter"
      assert first.provider_id == "101"
    end

    test "returns :none when TMDB has no recommendations", %{
      bypass: bypass,
      config: config,
      tmdb_id: tmdb_id
    } do
      stub_recommendations(bypass, tmdb_id, [])

      item = media_item_fixture(%{type: "movie", title: "Obscure", tmdb_id: tmdb_id})

      assert :none = Recommendations.for_media_item(item, config)
    end

    test "returns :none for an item with no tmdb_id", %{config: config} do
      item = %MediaItem{type: "movie", title: "No Id", tmdb_id: nil}

      assert :none = Recommendations.for_media_item(item, config)
    end

    test "returns :none and logs when the relay errors", %{
      bypass: bypass,
      config: config,
      tmdb_id: tmdb_id
    } do
      Bypass.stub(bypass, "GET", "/tmdb/movies/#{tmdb_id}", fn conn ->
        json(conn, 500, %{"status_message" => "boom"})
      end)

      item = media_item_fixture(%{type: "movie", title: "Broken", tmdb_id: tmdb_id})

      log =
        capture_log(fn ->
          assert :none = Recommendations.for_media_item(item, config)
        end)

      assert log =~ "Recommendations lookup failed"
    end

    test "returns :none for an unsupported media type", %{config: config, tmdb_id: tmdb_id} do
      item = %MediaItem{type: "music", title: "Album", tmdb_id: tmdb_id}

      assert :none = Recommendations.for_media_item(item, config)
    end
  end

  describe "for_tmdb_id/3" do
    test "serves a title that is not in the library", %{
      bypass: bypass,
      config: config,
      tmdb_id: tmdb_id
    } do
      stub_recommendations(bypass, tmdb_id, [
        %{"id" => 102, "title" => "Janet Planet", "release_date" => "2024-06-21"}
      ])

      assert {:ok, [first]} = Recommendations.for_tmdb_id(tmdb_id, :movie, config)
      assert first.title == "Janet Planet"
    end

    test "accepts a string id", %{bypass: bypass, config: config, tmdb_id: tmdb_id} do
      stub_recommendations(bypass, tmdb_id, [%{"id" => 103, "title" => "Tigertail"}])

      assert {:ok, [first]} = Recommendations.for_tmdb_id(to_string(tmdb_id), :movie, config)
      assert first.title == "Tigertail"
    end

    test "returns :none for a nil id", %{config: config} do
      assert :none = Recommendations.for_tmdb_id(nil, :movie, config)
    end

    # A Bypass with no stub fails the test on any request, so these also prove
    # the malformed ids never reach the relay rather than merely degrading once
    # they get there.
    test "returns :none for malformed ids without calling the relay", %{config: config} do
      for id <- ["", "abc", "12abc", " 12", 0, -5, %{}] do
        assert :none = Recommendations.for_tmdb_id(id, :movie, config),
               "expected :none for #{inspect(id)}"
      end
    end

    test "returns :none for an unsupported media type", %{config: config} do
      assert :none = Recommendations.for_tmdb_id(603, :music, config)
    end
  end
end
