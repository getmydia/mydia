defmodule Mydia.Library.ReleaseParser.QualityParityTest do
  @moduledoc """
  Acceptance gate for #1205: on the Sonarr and Radarr corpora, ReleaseParser
  never loses a quality value QualityParser found. Deleted once QualityParser
  wraps ReleaseParser.
  """
  use ExUnit.Case, async: true

  alias Mydia.Indexers.QualityParser
  alias Mydia.Library.ReleaseParser

  @fields [:resolution, :source, :codec, :audio, :hdr_format, :dolby_vision, :proper, :repack]

  # title => [{field, reason}]
  @known %{
    # QualityParser false positives
    "Series Title (1955) - 1954-01-23 05 00 00 - Cottage for Sale.ts" => [
      {:source, "'.ts' extension read as Telesync"}
    ],
    "Show - S03E01 - Episode Title Raw-HD.ts" => [
      {:source, "'.ts' extension read as Telesync"}
    ],
    "221206 Series Title! ep08(Tanaka Miku).ts" => [
      {:source, "'.ts' extension read as Telesync"}
    ],
    "221205 ABC123 17研究所！ #17.ts" => [{:source, "'.ts' extension read as Telesync"}],
    "www.5MovieRulz.tc - Movie (2000) Malayalam HQ HDRip - x264 - AAC - 700MB.mkv" => [
      {:source, "'.tc' domain read as Telecine"}
    ],
    "the.Series.1x13.circles.ws.xvidvd-tns" => [
      {:source, "'xvidvd' is an XviD DVD rip tag, not a source"},
      {:codec, "'xvidvd' read as XviD"}
    ],
    "the.Movie Name.1x13.circles.ws.xvidvd-tns" => [
      {:source, "'xvidvd' is an XviD DVD rip tag, not a source"},
      {:codec, "'xvidvd' read as XviD"}
    ],
    "Series.Title.2019.S02E07.Chapter.15.The.Believer.4Kto1080p.DSNYP.Webrip.x265.10bit.EAC3.5.1.Atmos.GokiTAoE" =>
      [{:resolution, "'4Kto1080p' is a 1080p downscale, not 2160p"}],
    "Movie.Name.2019.S02E07.Chapter.15.The.Believer.4Kto1080p.DSNYP.Webrip.x265.10bit.EAC3.5.1.Atmos.GokiTAoE" =>
      [{:resolution, "'4Kto1080p' is a 1080p downscale, not 2160p"}],
    "bn-BD" => [{:source, "locale code 'BD' read as BluRay"}],
    "[TMS-Remux].Series.Title.X.21.720p.[76EA1C53].mkv" => [
      {:source, "Sonarr fixture says HDTV-720p; TMS-Remux is a group name"}
    ],
    "Series.Galaxy.S01E01.33.720p.HDDVD.x264-SiNNERS.mkv" => [
      {:source, "HDDVD is not DVD"}
    ],
    "Movie.Name.S01E01.33.720p.HDDVD.x264-SiNNERS.mkv" => [{:source, "HDDVD is not DVD"}],
    "Movie.Title.2005.1080p.HDDVDRip.x264" => [{:source, "HDDVDRip is not DVDRip"}],
    "Fall.Of.The.Release.Groups.S02E13.1080p.BDLight.x265-AVCDVD" => [
      {:source, "group name 'AVCDVD' read as DVD"}
    ],
    "Movie.Name.2021.1080p.BDLight.x265-AVCDVD" => [
      {:source, "group name 'AVCDVD' read as DVD"}
    ],
    "Planet.Series.S01E11.Code.Deep.1080p.HD-DVD.DD.VC1-TRB" => [
      {:source, "HD-DVD is not DVD"}
    ],
    # ReleaseParser gap: no anchor at all, deliberate
    "tvs-amgo-dd51-dl-7p-azhd-x264-103" => [{:codec, "ReleaseParser gap: no anchor token"}],
    "Series.Title.S01EP01.English.AC3.DL.1080p.BluRay-Sonarr" => [
      {:audio, "ReleaseParser gap: AC3 sits between title words and DL, no anchor before it"}
    ],
    "Movie.Name.The.Lost.Pilots.Movie.HR.WS.PDTV.x264-DHD-Remux.mkv" => [
      {:codec, "ReleaseParser gap: no anchor token"}
    ],
    "E.010910.HDTVx264REPACKLOL.mp4" => [
      {:source, "ReleaseParser gap: source, codec, flag and group fused, no anchor token"},
      {:codec, "ReleaseParser gap: source, codec, flag and group fused, no anchor token"}
    ],
    # ReleaseParser gap: quality tag only in a parent directory
    "C:\\Test\\Unsorted\\Series.Title.S01E01.720p.HDTV\\tbbt101.avi" => [
      {:source, "ReleaseParser gap: tag only in parent directory"}
    ],
    "E:\\Downloads\\tv\\Series.Title.S01E01.720p.HDTV\\ajifajjjeaeaeqwer_eppj.avi" => [
      {:source, "ReleaseParser gap: tag only in parent directory"}
    ],
    "E:\\Downloads\\tv\\The.Series.S01E01.720p.HDTV\\ajifajjjeaeaeqwer_eppj.avi" => [
      {:source, "ReleaseParser gap: tag only in parent directory"}
    ],
    "E:\\Downloads\\tv\\Movie.Name.S01E01.720p.HDTV\\ajifajjjeaeaeqwer_eppj.avi" => [
      {:source, "ReleaseParser gap: tag only in parent directory"}
    ],
    "Series.of.Sonarr.S03.720p.BluRay-CLUE\\REWARD" => [
      {:source, "ReleaseParser gap: tag before backslash path"}
    ]
  }

  @titles for file <- ~w(sonarr_corpus.exs radarr_corpus.exs),
              {%{cases: cases}, _} =
                Code.eval_file(Path.join("test/fixtures/release_parser", file)),
              %{input: input} <- cases,
              uniq: true,
              do: input

  defp known?(title, field) do
    title |> then(&Map.get(@known, &1, [])) |> Enum.any?(&match?({^field, _}, &1))
  end

  test "ReleaseParser finds every quality value QualityParser finds" do
    losses =
      for title <- @titles,
          # ReleaseParser takes Path.basename; QualityParser will do the same swap
          rp = ReleaseParser.parse(String.replace(title, "/", " ")).quality,
          qp = QualityParser.parse(title),
          field <- @fields,
          Map.get(rp, field) in [nil, false],
          Map.get(qp, field) not in [nil, false],
          not known?(title, field),
          do: {field, title, Map.get(qp, field)}

    assert losses == [], """
    ReleaseParser lost #{length(losses)} value(s) QualityParser found:
    #{Enum.map_join(losses, "\n", &inspect/1)}
    """
  end
end
