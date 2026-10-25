defmodule Mydia.Library.ReleaseParser.QualityResolutionTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.ReleaseParser

  defp q(title), do: ReleaseParser.parse(title).quality

  test "glued and odd resolutions" do
    assert q("Fake.Movie.2020.HD1080p.BluRay.x264-GRP").resolution == "1080p"
    assert q("Fake.Movie.2020.camrip.360p.x264-GRP").resolution == "360p"
    assert q("Fake.Show.S01E01.540p.WEB-DL.x264-GRP").resolution == "540p"
  end

  test "a source glued to its resolution anchors the title zone" do
    result = ReleaseParser.parse("Fake.Show.S01E02.Bluray1080p")
    assert result.quality.resolution == "1080p"
    assert result.quality.source == "BluRay"

    result = ReleaseParser.parse("Fake.Movie.HD720p.x264-GRP")
    assert result.quality.resolution == "720p"
    assert result.title == "Fake Movie"
  end

  test "proper and repack" do
    proper = ReleaseParser.parse("Fake.Show.S01E01.PROPER.1080p.WEB-DL.x264-GRP")
    assert proper.quality.proper
    refute proper.quality.repack
    assert proper.title == "Fake Show"

    repack = ReleaseParser.parse("Fake.Show.S01E01.REPACK.720p.HDTV.x264-GRP")
    assert repack.quality.repack
    assert repack.season == 1
    assert repack.episodes == [1]
  end

  test "a revision flag dash-joined between codec and group" do
    result = ReleaseParser.parse("Fake.Show.S02E01.WS.PDTV.x264-REPACK-GRP")
    assert result.quality.repack
    assert result.release_group == "GRP"
  end

  test "standardize keeps the revision flags" do
    quality =
      ReleaseParser.parse("Fake.Show.S01E01.PROPER.720p.HDTV.x264-GRP", standardize: true).quality

    assert quality.proper
  end

  test "a revision tag closing the title zone is a tag, not a title word" do
    result = ReleaseParser.parse("Fake.Movie.PROPER.1080p.BluRay.x264-GRP")
    assert result.quality.proper
    assert result.title == "Fake Movie"

    result = ReleaseParser.parse("Fake.Movie.PROPER.REAL.RERIP.1080p.BluRay.x264-GRP")
    assert result.quality.proper
    assert result.quality.repack
  end

  test "a title word Proper stays in the title and sets nothing" do
    result = ReleaseParser.parse("The.Proper.Way.2020.1080p.WEB-DL.x264-GRP")
    refute result.quality.proper
    assert result.title == "The Proper Way"
    assert result.year == 2020

    result = ReleaseParser.parse("Repack.2020.720p.HDTV.x264-GRP")
    refute result.quality.repack
    assert result.title == "Repack"
  end

  test "a revision word directly before the year or episode marker is a title word" do
    result = ReleaseParser.parse("The.Last.Proper.2020.1080p.BluRay.x264-GRP")
    refute result.quality.proper
    assert {result.title, result.year} == {"The Last Proper", 2020}

    result = ReleaseParser.parse("Fake.Show.Repack.S01E01.720p.HDTV.x264-GRP")
    refute result.quality.repack
    assert {result.title, result.season, result.episodes} == {"Fake Show Repack", 1, [1]}

    # Scene names put the flag after the anchor.
    result = ReleaseParser.parse("Fake.Show.S01E01.PROPER.720p.HDTV.x264-GRP")
    assert result.quality.proper
    assert result.title == "Fake Show"
  end

  # QualityParser reads `Proper` anywhere as the flag, and an episode title
  # cannot be told from a tag here, so parity wins.
  test "an episode title opening with Proper sets the flag" do
    result = ReleaseParser.parse("Fake.Show.S01E01.Proper.Noun.720p.HDTV.x264-GRP")
    assert result.quality.proper
    assert result.title == "Fake Show"
  end

  test "a standalone RERIP is a repack" do
    result = ReleaseParser.parse("Fake.Movie.2020.RERIP.1080p.BluRay.x264-GRP")
    assert result.quality.repack
    refute result.quality.proper
    assert {result.title, result.year} == {"Fake Movie", 2020}
  end

  test "a revision tag leaves type and confidence alone" do
    plain = ReleaseParser.parse("Fake.Movie.2020.720p.HDTV.x264-GRP")
    tagged = ReleaseParser.parse("Fake.Movie.2020.REPACK.720p.HDTV.x264-GRP")

    assert tagged.quality.repack
    assert tagged.type == plain.type
    assert tagged.title == plain.title
    assert tagged.confidence == plain.confidence
    assert tagged.release_group == "GRP"
  end
end
