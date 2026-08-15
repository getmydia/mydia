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
end
