defmodule Mydia.Indexers.AudioPolicyCallSitesTest do
  @moduledoc """
  Every `RankingOptions.build/1` call site must decide the audio policy.

  A forgotten site ranks one search path language-blind, which is the bug this
  feature exists to fix, and nothing else would notice. Two layers: a source
  scan over `lib/` that fails on any build literal without an `audio_policy:`
  key, and behavioural checks on the manual-search builders, which are public.
  """
  use Mydia.DataCase, async: false

  import ExUnit.CaptureLog
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Media.AudioLanguagePolicy
  alias MydiaWeb.MediaLive.Show.SearchHelpers

  @build_literal ~r/RankingOptions\.build\(%\{(.*?)\n\s*\}\)/s

  test "every RankingOptions.build/1 literal in lib/ names :audio_policy" do
    literals =
      for path <- Path.wildcard("lib/**/*.ex"),
          [body] <- Regex.scan(@build_literal, File.read!(path), capture: :all_but_first),
          do: {path, body}

    # Six call sites exist today. A scan that finds fewer is a broken scan.
    assert length(literals) >= 6

    offenders = for {path, body} <- literals, not (body =~ "audio_policy:"), do: path
    assert offenders == []
  end

  test "manual search resolves the item's policy and a season's episode count" do
    show = media_item_fixture(%{type: "tv_show", title: "Kaiju Garden"})

    for number <- 1..3 do
      episode_fixture(%{media_item_id: show.id, season_number: 2, episode_number: number})
    end

    {:ok, show} = Mydia.Media.update_media_item(show, %{audio_languages: ["en"]})

    opts =
      SearchHelpers.build_manual_ranking_opts(%{
        media_item: show,
        manual_search_context: %{type: :season, season_number: 2},
        manual_search_query: "Kaiju Garden S02"
      })

    assert %AudioLanguagePolicy{source: :show, languages: ["en"]} =
             Keyword.get(opts, :audio_policy)

    assert Keyword.get(opts, :episode_count) == 3
  end

  test "the back-compat manual entries decide the policy explicitly" do
    profile = quality_profile_fixture()

    log =
      capture_log(fn ->
        SearchHelpers.sort_search_results([], :quality, profile, :movie, "query")

        SearchHelpers.profile_score_breakdown(
          %Mydia.Indexers.SearchResult{
            title: "Paper.Lantern.Club.2024.1080p",
            size: 5 * 1024 * 1024 * 1024,
            seeders: 10,
            leechers: 2,
            download_url: "magnet:?xt=urn:btih:test",
            indexer: "TestIndexer"
          },
          profile,
          :movie
        )
      end)

    refute log =~ "audio language preference will be ignored"
  end
end
