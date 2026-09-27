defmodule Mydia.Indexers.ProfileLimitsTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.{ProfileLimits, QualityParser, SearchResult}
  alias Mydia.Settings.QualityProfile

  @mb 1_048_576

  @episode "Some.Show.S01E01.1080p.WEB-DL.x264-GRP"
  @pack "Some.Show.S01.1080p.WEB-DL.x264-GRP"
  @movie "Some.Movie.2024.1080p.WEB-DL.x264-GRP"

  defp profile(standards), do: %QualityProfile{name: "Test", quality_standards: standards}

  defp release(title, size_mb) do
    %SearchResult{
      title: title,
      size: round(size_mb * @mb),
      seeders: 10,
      leechers: 0,
      download_url: "magnet:?xt=urn:btih:#{:erlang.phash2(title)}",
      indexer: "TestIndexer",
      quality: QualityParser.parse(title)
    }
  end

  defp episode_opts(standards), do: [quality_profile: profile(standards), media_type: :episode]
  defp movie_opts(standards), do: [quality_profile: profile(standards), media_type: :movie]

  describe "violation/2" do
    test "is nil when the profile sets no limits" do
      assert ProfileLimits.violation(release(@episode, 100), episode_opts(%{})) == nil
    end

    test "is nil with no profile at all" do
      assert ProfileLimits.violation(release(@episode, 100), media_type: :episode) == nil
    end

    test "reports an episode below the minimum size" do
      assert ProfileLimits.violation(
               release(@episode, 300),
               episode_opts(%{episode_min_size_mb: 512})
             ) ==
               "size_below_minimum: 300 MB < 512 MB"
    end

    test "reports an episode above the maximum size" do
      assert ProfileLimits.violation(
               release(@episode, 5000),
               episode_opts(%{episode_max_size_mb: 4096})
             ) == "size_above_maximum: 5000 MB > 4096 MB"
    end

    test "uses movie bounds for movies and episode bounds for episodes" do
      standards = %{movie_min_size_mb: 2048, episode_min_size_mb: 256}

      assert ProfileLimits.violation(release(@episode, 300), episode_opts(standards)) == nil

      assert "size_below_minimum: " <> _ =
               ProfileLimits.violation(release(@movie, 300), movie_opts(standards))
    end

    test "an explicit :size_range wins over the profile" do
      opts = episode_opts(%{episode_min_size_mb: 512}) ++ [size_range: {100, nil}]
      assert ProfileLimits.violation(release(@episode, 300), opts) == nil
    end

    test "a release of unknown size passes" do
      unknown = %{release(@episode, 1) | size: 0}
      assert ProfileLimits.violation(unknown, episode_opts(%{episode_min_size_mb: 512})) == nil
    end

    test "judges a season pack per episode when the episode count is known" do
      opts = episode_opts(%{episode_min_size_mb: 512, episode_max_size_mb: 4096})

      assert ProfileLimits.violation(release(@pack, 10_000), opts ++ [episode_count: 10]) == nil

      assert ProfileLimits.violation(release(@pack, 10_000), opts) ==
               "size_above_maximum: 10000 MB > 4096 MB"

      assert ProfileLimits.violation(release(@pack, 2_000), opts ++ [episode_count: 10]) ==
               "size_below_minimum: 200 MB per episode < 512 MB"
    end

    test "never divides a single episode" do
      opts = episode_opts(%{episode_max_size_mb: 4096}) ++ [episode_count: 10]

      assert ProfileLimits.violation(release(@episode, 10_000), opts) ==
               "size_above_maximum: 10000 MB > 4096 MB"
    end

    test "reports a resolution above the maximum" do
      assert ProfileLimits.violation(
               release("Some.Movie.2024.2160p.WEB-DL.x265-GRP", 8000),
               movie_opts(%{max_resolution: "1080p"})
             ) == "resolution_above_maximum: 2160p > 1080p"
    end

    test "reports a resolution below the minimum in the existing format" do
      assert ProfileLimits.violation(
               release("Some.Movie.2024.720p.WEB-DL.x264-GRP", 4000),
               movie_opts(%{min_resolution: "1080p"})
             ) == "resolution_below_minimum: 720p < 1080p"
    end

    test "require_hdr rejects a release with no HDR in its title" do
      opts = movie_opts(%{require_hdr: true})

      assert ProfileLimits.violation(release("Some.Movie.2024.2160p.WEB-DL.x265-GRP", 8000), opts) ==
               "hdr_required: no HDR in title"

      assert ProfileLimits.violation(
               release("Some.Movie.2024.2160p.WEB-DL.HDR10.x265-GRP", 8000),
               opts
             ) == nil
    end

    test "reports an excluded source" do
      assert ProfileLimits.violation(
               release("Some.Movie.2024.1080p.TELESYNC.HEVC.AAC2.0-GRP", 1400),
               movie_opts(%{excluded_sources: ["Telesync"]})
             ) == "excluded_source: Telesync"
    end
  end

  describe "reject/2" do
    setup do
      opts = episode_opts(%{episode_min_size_mb: 512})
      small = release("Some.Show.S01E01.1080p.WEB-DL.x264-SMALL", 300)
      ok = release("Some.Show.S01E01.1080p.WEB-DL.x264-OK", 1000)
      %{opts: opts, small: small, ok: ok}
    end

    test "removes violating releases by default", %{opts: opts, small: small, ok: ok} do
      assert ProfileLimits.reject([small, ok], opts) == [ok]
    end

    test "keeps everything when apply_profile_limits is false", %{
      opts: opts,
      small: small,
      ok: ok
    } do
      assert ProfileLimits.reject([small, ok], opts ++ [apply_profile_limits: false]) == [
               small,
               ok
             ]
    end
  end
end
