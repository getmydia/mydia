defmodule Mydia.Library.FileRankingTest do
  # Pure functions over structs: no database, no shared state.
  use ExUnit.Case, async: true

  alias Mydia.Library.FileRanking
  alias Mydia.Library.MediaFile

  describe "resolution_pixels/1" do
    test "maps every tier FileAnalyzer.extract_resolution/1 emits" do
      assert FileRanking.resolution_pixels("4K") == 2160
      assert FileRanking.resolution_pixels("2160p") == 2160
      assert FileRanking.resolution_pixels("1440p") == 1440
      assert FileRanking.resolution_pixels("1080p") == 1080
      assert FileRanking.resolution_pixels("720p") == 720
      assert FileRanking.resolution_pixels("480p") == 480
      assert FileRanking.resolution_pixels("360p") == 360
    end

    test "maps the extra spellings ReleaseParser can persist" do
      assert FileRanking.resolution_pixels("UHD") == 2160
      assert FileRanking.resolution_pixels("8K") == 4320
      assert FileRanking.resolution_pixels("4320p") == 4320
      assert FileRanking.resolution_pixels("576p") == 576
      assert FileRanking.resolution_pixels("540p") == 540
    end

    test "ignores case and surrounding whitespace" do
      assert FileRanking.resolution_pixels("  4k  ") == 2160
      assert FileRanking.resolution_pixels("1080P") == 1080
    end

    test "falls back to the trailing number for non-standard heights" do
      # FileAnalyzer emits "#{height}p" for anything off-tier.
      assert FileRanking.resolution_pixels("816p") == 816
      assert FileRanking.resolution_pixels("1920x1080") == 1080
    end

    test "returns 0 for nil and unparseable input so those files sort last" do
      assert FileRanking.resolution_pixels(nil) == 0
      assert FileRanking.resolution_pixels("") == 0
      assert FileRanking.resolution_pixels("unknown") == 0
    end

    test "treats interlaced resolutions as equal to progressive at the same height" do
      # ReleaseParser persists interlaced forms (e.g. "1080i"), treating them
      # as equal to progressive at the same resolution for ranking purposes.
      assert FileRanking.resolution_pixels("1080i") == 1080
      assert FileRanking.resolution_pixels("720i") == 720
      assert FileRanking.resolution_pixels("2160i") == 2160
    end

    test "ignores case for interlaced suffix" do
      assert FileRanking.resolution_pixels("1080I") == 1080
    end
  end

  describe "best/1" do
    test "returns nil for an empty list" do
      assert FileRanking.best([]) == nil
    end

    test "returns the only file when there is one" do
      only = file(id: "a", resolution: nil)
      assert FileRanking.best([only]).id == "a"
    end

    test "prefers 4K over 1080p whichever order the list arrives in" do
      hd = file(id: "a", resolution: "1080p")
      uhd = file(id: "b", resolution: "4K")

      assert FileRanking.best([hd, uhd]).id == "b"
      assert FileRanking.best([uhd, hd]).id == "b"
    end

    test "breaks a resolution tie on bitrate" do
      low = file(id: "a", resolution: "1080p", bitrate: 5_000_000)
      high = file(id: "b", resolution: "1080p", bitrate: 12_000_000)

      assert FileRanking.best([low, high]).id == "b"
      assert FileRanking.best([high, low]).id == "b"
    end

    test "resolution outranks bitrate" do
      # A 1080p remux can out-bitrate an efficient 4K HEVC encode. Resolution
      # still wins: this is why the ranking does not sort on bitrate alone.
      fat_hd = file(id: "a", resolution: "1080p", bitrate: 40_000_000)
      lean_uhd = file(id: "b", resolution: "4K", bitrate: 25_000_000)

      assert FileRanking.best([fat_hd, lean_uhd]).id == "b"
    end

    test "an unanalyzed file never outranks one with a known resolution" do
      unanalyzed = file(id: "a", resolution: nil, bitrate: 99_000_000)
      known = file(id: "b", resolution: "360p", bitrate: nil)

      assert FileRanking.best([unanalyzed, known]).id == "b"
    end

    test "treats a missing bitrate as zero rather than crashing" do
      no_bitrate = file(id: "a", resolution: "1080p", bitrate: nil)
      some_bitrate = file(id: "b", resolution: "1080p", bitrate: 1)

      assert FileRanking.best([no_bitrate, some_bitrate]).id == "b"
    end

    test "gives the same answer both ways when every quality signal ties" do
      x = file(id: "aaa", resolution: "1080p", bitrate: 1)
      y = file(id: "bbb", resolution: "1080p", bitrate: 1)

      assert FileRanking.best([x, y]).id == FileRanking.best([y, x]).id
    end

    test "an interlaced file outranks an unanalyzed file" do
      unanalyzed = file(id: "a", resolution: nil, bitrate: 99_000_000)
      interlaced = file(id: "b", resolution: "1080i", bitrate: nil)

      assert FileRanking.best([unanalyzed, interlaced]).id == "b"
    end
  end

  describe "sort/1" do
    test "orders best first" do
      sd = file(id: "a", resolution: "480p")
      uhd = file(id: "b", resolution: "4K")
      hd = file(id: "c", resolution: "1080p")

      assert Enum.map(FileRanking.sort([sd, uhd, hd]), & &1.id) == ["b", "c", "a"]
    end
  end

  defp file(attrs), do: struct!(MediaFile, Map.new(attrs))
end
