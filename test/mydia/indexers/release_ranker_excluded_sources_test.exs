defmodule Mydia.Indexers.ReleaseRankerExcludedSourcesTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.{QualityParser, ReleaseRanker, SearchResult}
  alias Mydia.Settings.QualityProfile

  defp telesync do
    SearchResult.new(
      title: "The.Odyssey.2026.1080p.TELESYNC.HEVC.AAC2.0-SLH",
      size: 3_293_700_000,
      seeders: 500,
      leechers: 40,
      download_url: "magnet:?xt=urn:btih:aaa",
      indexer: "Prowlarr",
      guid: "telesync-1"
    )
  end

  # Same release as `telesync/0`, but with :quality populated the way a real
  # indexer adapter would (via QualityParser.parse/1) rather than left nil.
  # This exercises the first result_source/1 clause (result.quality.source);
  # the plain telesync/0 helper above exercises the title-fallback clause.
  defp telesync_with_quality do
    title = "The.Odyssey.2026.1080p.TELESYNC.HEVC.AAC2.0-SLH"

    SearchResult.new(
      title: title,
      size: 3_293_700_000,
      seeders: 500,
      leechers: 40,
      download_url: "magnet:?xt=urn:btih:aaa2",
      indexer: "Prowlarr",
      guid: "telesync-quality-1",
      quality: QualityParser.parse(title)
    )
  end

  defp bluray do
    SearchResult.new(
      title: "The.Odyssey.2026.1080p.BluRay.x264-GRP",
      size: 8_000_000_000,
      seeders: 20,
      leechers: 2,
      download_url: "magnet:?xt=urn:btih:bbb",
      indexer: "Prowlarr",
      guid: "bluray-1"
    )
  end

  defp profile_excluding(sources) do
    %QualityProfile{
      name: "Test",
      quality_standards: %{excluded_sources: sources}
    }
  end

  describe "excluded sources are dropped before ranking" do
    test "an excluded release is dropped even when it is the ONLY candidate" do
      # The theatrical-window case: nothing but a telesync exists. The item must
      # stay wanted rather than take the cam.
      assert ReleaseRanker.select_best_result([telesync()],
               quality_profile: profile_excluding(["Telesync"]),
               expected_title: "The Odyssey"
             ) == nil
    end

    test "an excluded release with :quality populated is dropped even when it is the ONLY candidate" do
      # Same as above, but exercises the result.quality.source clause of
      # result_source/1 rather than the title-fallback clause.
      assert telesync_with_quality().quality.source == "Telesync"

      assert ReleaseRanker.select_best_result([telesync_with_quality()],
               quality_profile: profile_excluding(["Telesync"]),
               expected_title: "The Odyssey"
             ) == nil
    end

    test "a non-excluded release still wins when both are present" do
      result =
        ReleaseRanker.select_best_result([telesync(), bluray()],
          quality_profile: profile_excluding(["Telesync"]),
          expected_title: "The Odyssey"
        )

      refute is_nil(result)
      assert result.result.guid == "bluray-1"
    end

    test "an empty exclusion list changes nothing (the opt-out must work)" do
      result =
        ReleaseRanker.select_best_result([telesync()],
          quality_profile: profile_excluding([]),
          expected_title: "The Odyssey"
        )

      refute is_nil(result), "an empty exclusion list must not filter anything"
      assert result.result.guid == "telesync-1"
    end

    test "a profile without the key changes nothing" do
      profile = %QualityProfile{name: "NoKey", quality_standards: %{}}

      result =
        ReleaseRanker.select_best_result([telesync()],
          quality_profile: profile,
          expected_title: "The Odyssey"
        )

      refute is_nil(result)
    end

    test "a nil profile changes nothing" do
      result =
        ReleaseRanker.select_best_result([telesync()],
          quality_profile: nil,
          expected_title: "The Odyssey"
        )

      refute is_nil(result)
    end

    test "a release whose source could not be parsed is never dropped" do
      unknown =
        SearchResult.new(
          title: "The.Odyssey.2026.1080p.x264",
          size: 4_000_000_000,
          seeders: 10,
          leechers: 1,
          download_url: "magnet:?xt=urn:btih:ccc",
          indexer: "Prowlarr",
          guid: "unknown-1"
        )

      result =
        ReleaseRanker.select_best_result([unknown],
          quality_profile: profile_excluding(["Telesync", "CAM"]),
          expected_title: "The Odyssey"
        )

      refute is_nil(result)
    end
  end
end
