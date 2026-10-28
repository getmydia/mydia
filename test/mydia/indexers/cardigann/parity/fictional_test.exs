defmodule Mydia.Indexers.Cardigann.Parity.FictionalTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.Parity.{Fictional, Scrubber}

  describe "name/1" do
    test "is deterministic and two words" do
      assert Fictional.name("Lantern Harbor") == Fictional.name("Lantern Harbor")
      assert [_, _] = String.split(Fictional.name("Copper Vale"), " ")
    end

    test "differs between works and from the input" do
      names = for n <- 1..200, do: Fictional.name("work #{n}")
      assert length(Enum.uniq(names)) > 150

      for work <- names, do: refute(Fictional.name(work) == work)
    end

    test "is never empty" do
      assert Fictional.name("") != ""
    end
  end

  describe "split_title/1" do
    test "cuts at a year" do
      assert Scrubber.split_title("Lantern Harbor 2031 1080p WEB-DL") ==
               {"Lantern Harbor", "2031 1080p WEB-DL"}
    end

    test "cuts at an episode marker with dotted separators" do
      assert Scrubber.split_title("Quiet.Orchard.S01E02.720p") == {"Quiet.Orchard", "S01E02.720p"}
    end

    test "cuts at a season, resolution or source, case-insensitively" do
      assert Scrubber.split_title("Copper Vale S02 Complete") == {"Copper Vale", "S02 Complete"}
      assert Scrubber.split_title("Copper_Vale_720P") == {"Copper_Vale", "720P"}
      assert Scrubber.split_title("Copper-Vale-webrip-x264") == {"Copper-Vale", "webrip-x264"}
      assert Scrubber.split_title("Copper Vale bluray") == {"Copper Vale", "bluray"}
    end

    test "cuts at a bracketed year" do
      assert Scrubber.split_title("Copper Vale (2031) HDTV") == {"Copper Vale", "(2031) HDTV"}
    end

    test "a title without a marker is all work" do
      assert Scrubber.split_title("pebble-os-39-20240301.img.gz") ==
               {"pebble-os-39-20240301.img.gz", ""}
    end

    test "a leading number is the work, cut at the next marker" do
      assert Scrubber.split_title("1984 2031 1080p") == {"1984", "2031 1080p"}
      assert Scrubber.split_title("1984") == {"1984", ""}
    end

    test "a leading non-number marker leaves no work" do
      assert Scrubber.split_title("S01E02 720p HDTV") == {"", "S01E02 720p HDTV"}
    end

    test "markers only count as whole tokens" do
      assert Scrubber.split_title("Harbor2031 Webcast") == {"Harbor2031 Webcast", ""}
    end
  end
end
