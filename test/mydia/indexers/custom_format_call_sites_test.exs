defmodule Mydia.Indexers.CustomFormatCallSitesTest do
  @moduledoc """
  Guards against a RankingOptions.build/1 call site forgetting :custom_formats.

  A forgotten site makes custom formats silently inert for one search path,
  which is hard to notice and easy to reintroduce.
  """
  use Mydia.DataCase, async: false

  import ExUnit.CaptureLog
  import Mydia.SettingsFixtures

  alias Mydia.Settings.CustomFormats
  alias MydiaWeb.MediaLive.Show.SearchHelpers

  setup do
    profile = quality_profile_fixture()

    :ok =
      CustomFormats.set_assignments(profile, [
        %{format_slug: "lang-vff", score: 100, reject: false}
      ])

    %{profile: profile}
  end

  test "sort_search_results/5 passes formats", %{profile: profile} do
    log =
      capture_log(fn ->
        SearchHelpers.sort_search_results([], :quality, profile, :movie, "query")
      end)

    refute log =~ "custom formats will be ignored"
  end

  test "profile_score_breakdown/3 passes formats", %{profile: profile} do
    result = %Mydia.Indexers.SearchResult{
      title: "Film.2024.VFF.1080p",
      size: 5 * 1024 * 1024 * 1024,
      seeders: 10,
      leechers: 2,
      download_url: "magnet:?xt=urn:btih:test",
      indexer: "TestIndexer"
    }

    log =
      capture_log(fn ->
        SearchHelpers.profile_score_breakdown(result, profile, :movie)
      end)

    refute log =~ "custom formats will be ignored"
  end
end
