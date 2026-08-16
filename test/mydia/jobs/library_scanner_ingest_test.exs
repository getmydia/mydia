defmodule Mydia.Jobs.LibraryScannerIngestTest do
  @moduledoc """
  Pins the contract between the scheduled scan and `FileIngest`: an external
  provider match must never create a `MediaItem` from the cron scan, and it
  must leave a cached candidate behind so the import inbox can offer it.

  This exercises `FileIngest.ingest/3` directly with `policy: :local_only`,
  which is exactly what `Jobs.LibraryScanner.match_file_to_existing_items/4`
  now calls. `match_result.parsed_info` is built from a real
  `ReleaseParser.parse_with_path/1` call rather than a hand-built map: that is
  the shape `MetadataMatcher` actually hands the scanner in production (see
  the Task 3 regression this guards against in `file_ingest_test.exs`).
  """
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures

  alias Mydia.Jobs.LibraryScanner
  alias Mydia.Library
  alias Mydia.Library.FileIngest
  alias Mydia.Library.ReleaseParser
  alias Mydia.Library.Structs.ParsedFileInfo
  alias Mydia.Library.Structs.Quality

  defp external_match(overrides \\ %{}) do
    parsed = ReleaseParser.parse_with_path("/downloads/Game.of.Thrones.S01E01.1080p.mkv")
    assert %ParsedFileInfo{quality: %Quality{}} = parsed

    Map.merge(
      %{
        provider_id: "1399",
        provider_type: :tmdb,
        title: "Game of Thrones",
        year: 2011,
        match_confidence: 0.99,
        metadata: %{},
        from_local_db: false,
        parsed_info: parsed
      },
      Map.new(overrides)
    )
  end

  test "an external match leaves the file orphaned with a candidate" do
    file = orphaned_media_file_fixture()

    match = external_match()

    assert {:candidate, candidate} = FileIngest.ingest(file, match, policy: :local_only)

    assert candidate.provider_id == "1399"
    assert candidate.media_type == "tv_show"
    assert Library.get_media_file!(file.id).media_item_id == nil
  end

  test "the candidate carries the parsed season and episode numbers" do
    file = orphaned_media_file_fixture()

    parsed = ReleaseParser.parse_with_path("/downloads/Game.of.Thrones.S02E05-E06.1080p.mkv")
    assert %ParsedFileInfo{season: 2, episodes: [5, 6]} = parsed

    match = external_match(parsed_info: parsed)

    assert {:candidate, _candidate} = FileIngest.ingest(file, match, policy: :local_only)

    # Re-read from the database, not the struct `ingest/3` returned: that
    # struct proves nothing about what actually persisted through
    # `Library.MatchCandidate`'s `JsonMapType` column.
    assert [reloaded] = Library.list_match_candidates(file.id)
    assert reloaded.parsed_info["season"] == 2
    assert reloaded.parsed_info["episodes"] == [5, 6]
  end

  describe "a match from the local database still links" do
    test "links to the existing item, no relay round trip needed" do
      # A movie type deliberately avoids the TV episode-enrichment branch
      # (MetadataEnricher.enrich/2 skips it unconditionally for movies), and
      # a media item created moments ago is inside
      # MetadataEnricher.recently_enriched?/1's one-hour window, so
      # update_existing_media_item/5 takes the "skip re-fetch" branch and
      # never calls the relay. That makes this the one outcome of a routine
      # scan, a file matching an item already in the local database, that is
      # reachable in a deterministic, network-free test. The database
      # assertions below are what prove the link happened locally; there is
      # deliberately no wall-clock assertion, which would only add a CI flake
      # without ruling anything out that they do not.
      item = media_item_fixture(%{type: "movie", tmdb_id: 603, title: "The Matrix"})
      file = orphaned_media_file_fixture()

      parsed = ReleaseParser.parse_with_path("/downloads/The.Matrix.1999.1080p.mkv")
      assert %ParsedFileInfo{type: :movie} = parsed

      match = %{
        provider_id: "603",
        provider_type: :tmdb,
        title: "The Matrix",
        year: 1999,
        match_confidence: 1.0,
        metadata: %{},
        from_local_db: true,
        parsed_info: parsed
      }

      assert {:linked, linked} = FileIngest.ingest(file, match, policy: :local_only)
      assert linked.id == item.id
      assert Library.get_media_file!(file.id).media_item_id == item.id
    end
  end

  describe "scan_result_from_ingest/1" do
    test "maps a link to the enriched contract" do
      assert LibraryScanner.scan_result_from_ingest({:linked, %Mydia.Media.MediaItem{}}) ==
               {:ok, :enriched}
    end

    test "maps a cached candidate to :no_local_match" do
      assert LibraryScanner.scan_result_from_ingest({:candidate, %Library.MatchCandidate{}}) ==
               {:error, :no_local_match}
    end

    test "maps a library type mismatch to its own atom, ahead of the generic error clause" do
      assert LibraryScanner.scan_result_from_ingest(
               {:error, {:library_type_mismatch, "series file in a movies-only library"}}
             ) == {:error, :library_type_mismatch}
    end

    test "maps any other error to :enrichment_failed" do
      assert LibraryScanner.scan_result_from_ingest({:error, :some_other_reason}) ==
               {:error, :enrichment_failed}

      assert LibraryScanner.scan_result_from_ingest({:error, {:metadata_fetch_failed, :timeout}}) ==
               {:error, :enrichment_failed}
    end

    test "maps :no_match to :no_matches_found" do
      assert LibraryScanner.scan_result_from_ingest(:no_match) == {:error, :no_matches_found}
    end
  end
end
