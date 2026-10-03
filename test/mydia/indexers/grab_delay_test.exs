defmodule Mydia.Indexers.GrabDelayTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.GrabDelay
  alias Mydia.Indexers.QualityParser
  alias Mydia.Indexers.SearchResult
  alias Mydia.Indexers.Structs.{RankedResult, ScoreBreakdown}
  alias Mydia.Settings.QualityProfile

  @now ~U[2031-03-10 12:00:00Z]

  defp ranked(title, published_at) do
    result = %SearchResult{
      title: title,
      size: 1_500_000_000,
      seeders: 40,
      leechers: 2,
      download_url: "magnet:?xt=urn:btih:#{String.duplicate("a", 40)}",
      indexer: "Test Indexer",
      quality: QualityParser.parse(title),
      published_at: published_at
    }

    breakdown = %ScoreBreakdown{
      quality: 0.0,
      seeders: 0.0,
      size: 0.0,
      age: 0.0,
      title_match: 0.0,
      tag_bonus: 0.0,
      custom_format_score: 0.0,
      total: 500.0
    }

    RankedResult.new(%{result: result, score: 500.0, breakdown: breakdown})
  end

  defp hours_ago(h), do: DateTime.add(@now, -h * 3600, :second)

  defp profile(attrs) do
    struct(
      %QualityProfile{
        name: "Delay",
        upgrade_until_score: nil,
        grab_delay_hours: 24,
        quality_standards: %{preferred_resolutions: ["1080p"]}
      },
      attrs
    )
  end

  defp opts(profile), do: [quality_profile: profile, media_type: :episode]

  test "an empty list is :none" do
    assert GrabDelay.select([], opts(profile(%{})), @now) == :none
  end

  test "a zero delay grabs the best at once" do
    best = ranked("Lantern.Vale.S01E01.720p.WEB-DL.x264-GRP", hours_ago(1))
    assert {:grab, ^best} = GrabDelay.select([best], opts(profile(%{grab_delay_hours: 0})), @now)
  end

  test "no profile grabs at once" do
    best = ranked("Lantern.Vale.S01E01.720p.WEB-DL.x264-GRP", hours_ago(1))
    assert {:grab, ^best} = GrabDelay.select([best], [media_type: :episode], @now)
  end

  test "bypass grabs at once" do
    best = ranked("Lantern.Vale.S01E01.720p.WEB-DL.x264-GRP", hours_ago(1))
    assert {:grab, ^best} = GrabDelay.select([best], opts(profile(%{})), @now, bypass: true)
  end

  test "waits until the oldest acceptable release is delay hours old" do
    best = ranked("Lantern.Vale.S01E01.1080p.WEB-DL.x264-GRP", hours_ago(1))
    older = ranked("Lantern.Vale.S01E01.720p.WEB-DL.x264-GRP", hours_ago(5))

    expected_until = DateTime.add(hours_ago(5), 24 * 3600, :second)

    assert {:wait, ^expected_until, ^best} =
             GrabDelay.select([best, older], opts(profile(%{})), @now)
  end

  test "a newer, better release does not reset the clock" do
    best = ranked("Lantern.Vale.S01E01.1080p.WEB-DL.x264-GRP", hours_ago(1))
    older = ranked("Lantern.Vale.S01E01.720p.WEB-DL.x264-GRP", hours_ago(25))

    assert {:grab, ^best} = GrabDelay.select([best, older], opts(profile(%{})), @now)
  end

  test "a release with no publish date never blocks the grab" do
    best = ranked("Lantern.Vale.S01E01.1080p.WEB-DL.x264-GRP", hours_ago(1))
    undated = ranked("Lantern.Vale.S01E01.720p.WEB-DL.x264-GRP", nil)

    assert {:grab, ^best} = GrabDelay.select([best, undated], opts(profile(%{})), @now)
  end

  test "a best release at or above the upgrade cutoff grabs at once" do
    best = ranked("Lantern.Vale.S01E01.1080p.WEB-DL.x264-GRP", hours_ago(1))

    assert {:grab, ^best} =
             GrabDelay.select([best], opts(profile(%{upgrade_until_score: 0})), @now)
  end

  test "a best release below the upgrade cutoff still waits" do
    best = ranked("Lantern.Vale.S01E01.1080p.WEB-DL.x264-GRP", hours_ago(1))

    assert {:wait, _until, ^best} =
             GrabDelay.select([best], opts(profile(%{upgrade_until_score: 100})), @now)
  end
end
