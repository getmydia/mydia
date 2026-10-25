defmodule Mydia.Library.ReleaseParser.QualityHdrTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.ReleaseParser

  defp hdr(title) do
    q = ReleaseParser.parse(title).quality
    {q.hdr_format, q.dolby_vision}
  end

  test "Dolby Vision keeps its HDR base" do
    assert hdr("Fake.Movie.2020.2160p.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-GRP") == {:hdr10, true}
    assert hdr("Fake.Movie.2020.2160p.WEB-DL.DV.HDR10.H.265-GRP") == {:hdr10, true}
    assert hdr("Fake.Movie.2020.2160p.WEB-DL.DV.HDR10+.H.265-GRP") == {:hdr10_plus, true}
    assert hdr("Fake.Movie.2020.2160p.WEB-DL.DV.HDR10Plus.H.265-GRP") == {:hdr10_plus, true}
    assert hdr("Fake.Movie.2020.2160p.BluRay.HDR10.DoVi.x265-GRP") == {:hdr10, true}
  end

  test "single tokens" do
    assert hdr("Fake.Show.S01E01.2160p.HLG.WEB-DL.H.265-GRP") == {:hlg, false}
    assert hdr("Fake.Movie.2020.2160p.WEB-DL.DV.H.265-GRP") == {nil, true}
    assert hdr("Fake.Movie.2020.2160p.WEB-DL.HDR.H.265-GRP") == {:hdr10, false}
    assert hdr("Fake.Movie.2020.1080p.BluRay.x264-GRP") == {nil, false}
  end

  test "the first base token wins" do
    assert hdr("Fake.Movie.2020.2160p.WEB-DL.HDR10+.HDR10.DV.H.265-GRP") == {:hdr10_plus, true}
    assert hdr("Fake.Movie.2020.2160p.WEB-DL.HLG.HDR10.H.265-GRP") == {:hlg, false}
  end

  test "spaced and separated spellings" do
    assert hdr("Fake Movie 2020 2160p WEB-DL DV HDR10 PLUS DDP5 1 H265-GRP") ==
             {:hdr10_plus, true}

    assert hdr("Fake.Movie.2020.2160p.WEB-DL.DV.HDR10.PLUS.H.265-GRP") == {:hdr10_plus, true}
    assert hdr("Fake.Movie.2020.2160p.WEB-DL.HDR10-PLUS.H.265-GRP") == {:hdr10_plus, false}
    assert hdr("Fake Movie 2020 [HEVC, HDR10, Dolby Vision, WEB-DL 2160p]") == {:hdr10, true}
    assert hdr("Fake Movie 2020 2160p WEB-DL (HDR10, DV) H 265-GRP") == {:hdr10, true}
  end

  test "HDR words in the title are not read as HDR" do
    assert hdr("Dv.Hdr.Fake.Story.2020.1080p.BluRay.x264-GRP") == {nil, false}
    assert hdr("The.Dv.Files.S01E01.1080p.WEB-DL.H.264-GRP") == {nil, false}
    assert hdr("Dolby.Vision.Story.2020.1080p.BluRay.x264-GRP") == {nil, false}
  end

  # The HDR10 + PLUS rejoin only reads tokens that reached the extractor,
  # and a title-zone HDR word with title words after it never does. The
  # HDR word itself still drops out of the title, as `Hdr` does in
  # `Dv.Hdr.Fake.Story`: it keeps its :hdr label and is not reclaimed.
  test "HDR10 and Plus in the title are not HDR10+" do
    parsed = ReleaseParser.parse("Hdr10.Plus.Something.2020.1080p.BluRay.x264-GRP")
    assert {parsed.quality.hdr_format, parsed.quality.dolby_vision} == {nil, false}
    assert parsed.title == "Plus Something"
    assert parsed.year == 2020
  end

  # Pinned as it stands: an HDR word closing the title zone is read as a
  # tag, the same rule as audio (`German.DTS.720p`), so a one-word title
  # followed by it loses the word.
  test "an HDR word closing the title zone is a tag" do
    parsed = ReleaseParser.parse("Fake.Hdr.2020.1080p.BluRay.x264-GRP")
    assert parsed.quality.hdr_format == :hdr10
    assert parsed.title == "Fake"
  end
end
