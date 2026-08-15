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
  alias Mydia.Metadata.Structs.SearchResult

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

  defp result(attrs) do
    struct!(
      %SearchResult{provider_id: "1", provider: :metadata_relay, media_type: :movie},
      attrs
    )
  end

  defp titles(results), do: Enum.map(results, & &1.title)

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

    test "caps what the relay returns", %{bypass: bypass, config: config, tmdb_id: tmdb_id} do
      stub_recommendations(
        bypass,
        tmdb_id,
        for n <- 1..20 do
          %{
            "id" => 1_000 + n,
            "title" => "Rec #{n}",
            "vote_average" => 7.0,
            "vote_count" => 100
          }
        end
      )

      item = media_item_fixture(%{type: "movie", title: "Prolific", tmdb_id: tmdb_id})

      assert {:ok, results} = Recommendations.for_media_item(item, config)
      assert length(results) == 12
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

  describe "rank/1" do
    # The defect this fixes: TMDB's raw order let a 10.0 from three voters lead
    # the rail. The prior pulls it back toward the set mean.
    test "a high rating from few voters does not lead the rail" do
      ranked =
        Recommendations.rank([
          result(%{provider_id: "1", title: "Three Voters", vote_average: 10.0, vote_count: 3}),
          result(%{
            provider_id: "2",
            title: "Crowd Pleaser",
            vote_average: 8.2,
            vote_count: 5_000
          }),
          result(%{provider_id: "3", title: "Solid", vote_average: 7.5, vote_count: 1_200}),
          result(%{provider_id: "4", title: "Mediocre", vote_average: 6.0, vote_count: 800})
        ])

      assert titles(ranked) == ["Crowd Pleaser", "Three Voters", "Solid", "Mediocre"]
    end

    test "an unrated entry lands mid-pack rather than at either end" do
      ranked =
        Recommendations.rank([
          result(%{
            provider_id: "1",
            title: "Crowd Pleaser",
            vote_average: 8.2,
            vote_count: 5_000
          }),
          result(%{provider_id: "2", title: "Solid", vote_average: 7.5, vote_count: 1_200}),
          result(%{provider_id: "3", title: "Unrated", vote_average: nil, vote_count: nil}),
          result(%{provider_id: "4", title: "Mediocre", vote_average: 6.0, vote_count: 800})
        ])

      assert titles(ranked) == ["Crowd Pleaser", "Solid", "Unrated", "Mediocre"]
    end

    test "ties fall back to TMDB's own order" do
      ranked =
        Recommendations.rank([
          result(%{provider_id: "1", title: "First", vote_average: 7.0, vote_count: 100}),
          result(%{provider_id: "2", title: "Second", vote_average: 7.0, vote_count: 100})
        ])

      assert titles(ranked) == ["First", "Second"]
    end

    test "keeps TMDB's order when nothing in the set is rated" do
      ranked =
        Recommendations.rank([
          result(%{provider_id: "1", title: "Zeta", vote_average: nil, vote_count: nil}),
          result(%{provider_id: "2", title: "Yankee", vote_average: nil, vote_count: 0}),
          result(%{provider_id: "3", title: "Xray", vote_average: 0.0, vote_count: 0})
        ])

      assert titles(ranked) == ["Zeta", "Yankee", "Xray"]
    end

    # Regression: this entry used to contribute 0.0 to the set mean and then
    # sink to last, because the mean selected on votes but averaged a rating
    # that defaults to 0.0 when nil.
    test "an entry with votes but no rating lands mid-pack and does not drag the mean" do
      ranked =
        Recommendations.rank([
          result(%{
            provider_id: "1",
            title: "Crowd Pleaser",
            vote_average: 8.2,
            vote_count: 5_000
          }),
          result(%{provider_id: "2", title: "Solid", vote_average: 7.5, vote_count: 1_200}),
          result(%{provider_id: "3", title: "Voted Unrated", vote_average: nil, vote_count: 800}),
          result(%{provider_id: "4", title: "Mediocre", vote_average: 6.0, vote_count: 800})
        ])

      assert titles(ranked) == ["Crowd Pleaser", "Solid", "Voted Unrated", "Mediocre"]
    end

    test "caps the list at twelve" do
      results =
        for n <- 1..20 do
          result(%{
            provider_id: to_string(n),
            title: "Title #{n}",
            vote_average: 7.0,
            vote_count: 100
          })
        end

      assert length(Recommendations.rank(results)) == 12
    end

    test "an empty list stays empty" do
      assert Recommendations.rank([]) == []
    end
  end
end
