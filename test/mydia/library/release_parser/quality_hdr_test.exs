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
end
