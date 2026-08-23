defmodule Mydia.Library.Structs.QualityTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.Structs.Quality

  describe "new/1" do
    test "defaults boolean flags to false and others to nil" do
      q = Quality.new(resolution: "1080p")
      assert q.resolution == "1080p"
      assert q.source == nil
      assert q.codec == nil
      assert q.audio == nil
      assert q.hdr_format == nil
      assert q.dolby_vision == false
      assert q.proper == false
      assert q.repack == false
    end

    test "accepts a map" do
      q =
        Quality.new(%{resolution: "2160p", hdr_format: :hdr10, dolby_vision: true, proper: true})

      assert q.resolution == "2160p"
      assert q.hdr_format == :hdr10
      assert q.dolby_vision == true
      assert q.proper == true
      assert q.repack == false
    end
  end

  describe "hdr?/1" do
    test "true for a canonical base" do
      assert Quality.hdr?(%Quality{hdr_format: :hdr10})
    end

    test "true for Dolby Vision with no base, which is how profile 5 parses" do
      assert Quality.hdr?(%Quality{hdr_format: nil, dolby_vision: true})
    end

    test "false for SDR" do
      refute Quality.hdr?(%Quality{})
    end
  end

  describe "empty/0 and empty?/1" do
    test "empty/0 is empty?" do
      assert Quality.empty?(Quality.empty())
    end

    test "a struct with only flags set is still empty" do
      assert Quality.empty?(%Quality{dolby_vision: false, proper: false, repack: false})
    end

    test "a struct with content is not empty" do
      refute Quality.empty?(%Quality{resolution: "1080p"})
      refute Quality.empty?(%Quality{hdr_format: :hdr10})
    end

    test "a Dolby Vision only struct (no base) is not empty" do
      refute Quality.empty?(%Quality{dolby_vision: true})
    end
  end

  describe "format/1" do
    test "joins resolution, source, codec, audio" do
      q = %Quality{resolution: "1080p", source: "BluRay", codec: "x264", audio: "DTS-HD MA"}
      assert Quality.format(q) == "1080p BluRay x264 DTS-HD MA"
    end

    test "renders Dolby Vision over its base" do
      assert Quality.format(%Quality{resolution: "2160p", hdr_format: :hdr10, dolby_vision: true}) ==
               "2160p Dolby Vision"
    end

    test "renders a bare base" do
      assert Quality.format(%Quality{resolution: "2160p", hdr_format: :hdr10}) == "2160p HDR10"
    end

    test "shows Dolby Vision when there is no base at all" do
      q = %Quality{resolution: "2160p", source: "BluRay", dolby_vision: true}
      assert Quality.format(q) == "2160p BluRay Dolby Vision"
    end

    test "appends PROPER and REPACK" do
      assert Quality.format(%Quality{resolution: "1080p", source: "BluRay", proper: true}) ==
               "1080p BluRay PROPER"

      assert Quality.format(%Quality{resolution: "720p", source: "WEB-DL", repack: true}) ==
               "720p WEB-DL REPACK"
    end

    test "empty struct formats to empty string; nil to nil" do
      assert Quality.format(Quality.empty()) == ""
      assert Quality.format(nil) == nil
    end
  end

  describe "from_map/1" do
    test "reconstructs from string-keyed map with flag defaults" do
      q = Quality.from_map(%{"resolution" => "1080p", "source" => "BluRay"})
      assert %Quality{} = q
      assert q.resolution == "1080p"
      assert q.source == "BluRay"
      assert q.hdr_format == nil
      assert q.dolby_vision == false
      assert q.proper == false
      assert q.repack == false
    end

    test "honors atom keys and explicit flags" do
      q =
        Quality.from_map(%{
          resolution: "2160p",
          hdr_format: :hdr10,
          dolby_vision: true,
          repack: true
        })

      assert q.hdr_format == :hdr10
      assert q.dolby_vision == true
      assert q.repack == true
    end

    test "decodes a stored string hdr_format back to its atom" do
      q = Quality.from_map(%{"resolution" => "2160p", "hdr_format" => "hdr10+"})
      assert q.hdr_format == :hdr10_plus
    end

    test "an unrecognized stored hdr_format string decodes to nil" do
      q = Quality.from_map(%{"resolution" => "2160p", "hdr_format" => "garbage"})
      assert q.hdr_format == nil
    end

    test "nil maps to nil" do
      assert Quality.from_map(nil) == nil
    end
  end
end
