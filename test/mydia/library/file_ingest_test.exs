defmodule Mydia.Library.FileIngestTest do
  @moduledoc """
  The `:local_only` policy is a regression guard, not a new feature. It must
  reproduce what `Jobs.LibraryScanner` did before the extraction: link a match
  that came from the local database, and leave an external match orphaned with
  its candidate cached for manual review.
  """
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures

  alias Mydia.Library
  alias Mydia.Library.FileIngest
  alias Mydia.Library.ReleaseParser
  alias Mydia.Library.Structs.ParsedFileInfo
  alias Mydia.Library.Structs.Quality

  defp match(overrides) do
    Map.merge(
      %{
        provider_id: "603",
        provider_type: :tmdb,
        title: "The Matrix",
        year: 1999,
        match_confidence: 0.95,
        metadata: %{},
        from_local_db: false,
        parsed_info: %{type: :movie, season: nil, episodes: []}
      },
      Map.new(overrides)
    )
  end

  describe "ingest/3 with no match" do
    test "returns :no_match and records the attempt" do
      file = orphaned_media_file_fixture()

      assert :no_match = FileIngest.ingest(file, nil, policy: :create_items)

      assert [candidate] = Library.list_match_candidates(file.id)
      assert candidate.attempts == 1
      assert is_nil(candidate.provider_id)
    end
  end

  describe "ingest/3 with policy :local_only" do
    test "caches a candidate and does not link an external match" do
      file = orphaned_media_file_fixture()

      assert {:candidate, candidate} =
               FileIngest.ingest(file, match(from_local_db: false), policy: :local_only)

      assert candidate.provider_id == "603"
      assert candidate.confidence == 0.95

      assert Library.get_media_file!(file.id).media_item_id == nil
    end

    test "caches a candidate for a high confidence external match too" do
      file = orphaned_media_file_fixture()

      assert {:candidate, _} =
               FileIngest.ingest(file, match(from_local_db: false, match_confidence: 1.0),
                 policy: :local_only
               )

      assert Library.get_media_file!(file.id).media_item_id == nil
    end
  end

  describe "ingest/3 with policy :create_items" do
    test "caches a candidate below the confidence threshold" do
      file = orphaned_media_file_fixture()

      assert {:candidate, candidate} =
               FileIngest.ingest(file, match(match_confidence: 0.4), policy: :create_items)

      assert candidate.confidence == 0.4
      assert Library.get_media_file!(file.id).media_item_id == nil
    end

    test "honours a caller supplied threshold" do
      file = orphaned_media_file_fixture()

      assert {:candidate, _} =
               FileIngest.ingest(file, match(match_confidence: 0.85),
                 policy: :create_items,
                 threshold: 0.9
               )
    end
  end

  describe "default_threshold/0" do
    test "matches the confidence the old wizard auto-selected at" do
      assert FileIngest.default_threshold() == 0.8
    end
  end

  describe "parsed_info round trip" do
    test "atom-keyed, atom-valued parsed_info survives a real database round trip" do
      file = orphaned_media_file_fixture()

      assert {:candidate, _candidate} =
               FileIngest.ingest(
                 file,
                 match(
                   match_confidence: 0.4,
                   parsed_info: %{type: :tv_show, season: 2, episodes: [5, 6]}
                 ),
                 policy: :create_items
               )

      # Re-read from the database rather than asserting on the struct
      # `ingest/3` just handed back: that struct proves nothing about what
      # JsonMapType actually persisted. A broken implementation that skips
      # `storable_parsed_info/1` (or stringifies indiscriminately, turning
      # `season` into "2") would build an identical-looking in-memory struct
      # but fail this assertion once it comes back through the DB round trip.
      assert [reloaded] = Library.list_match_candidates(file.id)

      assert reloaded.parsed_info["type"] == "tv_show"
      assert reloaded.parsed_info["season"] == 2
      assert reloaded.parsed_info["episodes"] == [5, 6]
    end

    test "a real %ParsedFileInfo{} with a nested %Quality{} struct survives ingest and the database round trip" do
      file = orphaned_media_file_fixture()

      # This is what production actually hands `ingest/3`: `MetadataMatcher`
      # sets `match_result.parsed_info` from `ReleaseParser.parse_with_path/2`,
      # never from a hand-built map. The struct carries a nested `%Quality{}`
      # (no `Jason.Encoder`) plus parser internals that have no business in
      # this column, which is exactly the shape the synthetic-map test above
      # cannot exercise.
      parsed = ReleaseParser.parse_with_path("/downloads/The.Mandalorian.S02E05.1080p.mkv")
      assert %ParsedFileInfo{quality: %Quality{}} = parsed

      assert {:candidate, _candidate} =
               FileIngest.ingest(
                 file,
                 match(match_confidence: 0.4, parsed_info: parsed),
                 policy: :create_items
               )

      # Re-read from the database, not the struct `ingest/3` returned.
      assert [reloaded] = Library.list_match_candidates(file.id)

      assert reloaded.parsed_info["type"] == "tv_show"
      assert reloaded.parsed_info["season"] == 2
      assert reloaded.parsed_info["episodes"] == [5]
      assert reloaded.parsed_info["is_sample"] == false
      assert reloaded.parsed_info["is_trailer"] == false
      assert reloaded.parsed_info["is_extra"] == false
    end
  end
end
