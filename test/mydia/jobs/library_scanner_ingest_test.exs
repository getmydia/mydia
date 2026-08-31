defmodule Mydia.Jobs.LibraryScannerIngestTest do
  @moduledoc """
  Pins the contract between the scheduled scan's discovery path and
  `FileIngest`, using real `ReleaseParser.parse_with_path/1` output rather
  than a hand-built map -- the shape `Mydia.Library.BatchMatcher` and
  `Mydia.Library.MetadataMatcher` actually hand a match in production (see
  the Task 3 regression this guards against in `file_ingest_test.exs`).

  The general promote/candidate/threshold contract is already covered by
  `file_ingest_test.exs` with synthetic matches. What is distinct here is
  the extras-review-only override `Mydia.Jobs.LibraryScanner.discover_unknown_paths/3`
  depends on: a sample/trailer/extra must never auto-promote under the
  scanner's `:unattended` policy, no matter how confident its match, because
  `Mydia.Library.BatchMatcher` reuses one anchor folder's match across every
  file beneath it -- extras included.

  Every promotion test below matches against a `media_item_fixture` created
  moments earlier with the same provider id: `MetadataEnricher` links to an
  existing local item by provider id and, being inside its "recently
  enriched" window, never re-fetches -- so promotion runs for real with no
  relay call anywhere in the chain (see `file_ingest_test.exs` for the same
  technique).
  """
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library.FileIngest
  alias Mydia.Library.MediaFile
  alias Mydia.Library.ReleaseParser
  alias Mydia.Library.Structs.ParsedFileInfo
  alias Mydia.Library.Structs.Quality
  alias Mydia.Repo

  defp candidate(relative_path, opts \\ []) do
    type = Keyword.get(opts, :type, "movies")

    media_type =
      Keyword.get(opts, :media_type, if(type == "series", do: "tv_show", else: "movie"))

    library_path = library_path_fixture(%{type: type})

    import_candidate_fixture(%{
      library_path_id: library_path.id,
      relative_path: relative_path,
      media_type: media_type
    })
  end

  defp external_match(parsed, overrides \\ %{}) do
    Map.merge(
      %{
        provider_id: "603",
        provider_type: :tmdb,
        title: "The Matrix",
        year: 1999,
        match_confidence: 0.99,
        metadata: %{},
        from_local_db: false,
        parsed_info: parsed
      },
      Map.new(overrides)
    )
  end

  test "an unattended, confident match against a known local item promotes the candidate" do
    movie = media_item_fixture(%{type: "movie", tmdb_id: 603, title: "The Matrix", year: 1999})

    parsed = ReleaseParser.parse_with_path("/downloads/The.Matrix.1999.1080p.mkv")
    assert %ParsedFileInfo{quality: %Quality{}, type: :movie, is_extra: false} = parsed

    file = candidate("The Matrix (1999)/The.Matrix.1999.1080p.mkv")
    match = external_match(parsed, %{match_confidence: 1.0})

    assert {:promoted, [media_file]} = FileIngest.ingest(file, match, policy: :unattended)
    assert media_file.media_item_id == movie.id
  end

  test "the candidate carries the parsed season and episode numbers when it stays in review" do
    parsed = ReleaseParser.parse_with_path("/downloads/Game.of.Thrones.S02E05-E06.1080p.mkv")
    assert %ParsedFileInfo{season: 2, episodes: [5, 6]} = parsed

    file =
      candidate("Game of Thrones/Season 02/Game.of.Thrones.S02E05-E06.1080p.mkv", type: "series")

    match =
      external_match(parsed, %{provider_id: "1399", title: "Game of Thrones", year: 2011})

    assert {:candidate, updated} = FileIngest.ingest(file, match, policy: :review)
    assert updated.parsed_info["season"] == 2
    assert updated.parsed_info["episodes"] == [5, 6]
  end

  describe "extras stay review-only under the unattended scanner policy" do
    test "a sample file never promotes, even at full confidence" do
      parsed = ReleaseParser.parse_with_path("/downloads/Movie/Movie-sample.mkv")
      assert %ParsedFileInfo{is_sample: true} = parsed

      file = candidate("Movie/Movie-sample.mkv")
      match = external_match(parsed, %{match_confidence: 1.0})

      assert {:candidate, _updated} = FileIngest.ingest(file, match, policy: :unattended)
      refute Repo.exists?(MediaFile)
    end

    test "a trailer never promotes, even at full confidence" do
      parsed = ReleaseParser.parse_with_path("/downloads/Movie/Movie-trailer.mkv")
      assert %ParsedFileInfo{is_trailer: true} = parsed

      file = candidate("Movie/Movie-trailer.mkv")
      match = external_match(parsed, %{match_confidence: 1.0})

      assert {:candidate, _updated} = FileIngest.ingest(file, match, policy: :unattended)
      refute Repo.exists?(MediaFile)
    end

    test "a folder-detected extra never promotes, even at full confidence" do
      parsed = ReleaseParser.parse_with_path("/downloads/Movie/Featurettes/making-of.mkv")
      assert %ParsedFileInfo{is_extra: true} = parsed

      file = candidate("Movie/Featurettes/making-of.mkv")
      match = external_match(parsed, %{match_confidence: 1.0})

      assert {:candidate, _updated} = FileIngest.ingest(file, match, policy: :unattended)
      refute Repo.exists?(MediaFile)
    end

    test "an extra stays review-only even when the match itself omits parsed_info" do
      # BatchMatcher's head-file result carries whatever the underlying
      # matcher returned; a matcher that omits :parsed_info (like
      # Mydia.Library.EchoMatcher) leaves FileIngest to fall back to the
      # candidate's own stored parsed_info, captured at discovery time.
      library_path = library_path_fixture(%{type: "movies"})

      file =
        import_candidate_fixture(%{
          library_path_id: library_path.id,
          relative_path: "Movie/Movie-trailer.mkv",
          parsed_info: %{
            "type" => "movie",
            "is_sample" => false,
            "is_trailer" => true,
            "is_extra" => false
          }
        })

      parsed = ReleaseParser.parse_with_path("/downloads/Movie/Movie-trailer.mkv")

      match =
        parsed
        |> external_match()
        |> Map.delete(:parsed_info)
        |> Map.put(:match_confidence, 1.0)

      assert {:candidate, _updated} = FileIngest.ingest(file, match, policy: :unattended)
      refute Repo.exists?(MediaFile)
    end
  end
end
