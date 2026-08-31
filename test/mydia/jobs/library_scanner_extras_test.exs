defmodule Mydia.Jobs.LibraryScannerExtrasTest do
  @moduledoc """
  Extras (samples, trailers, bonus content) are persisted rather than
  silently dropped, so a file the scanner decided to ignore leaves a trace
  an operator can see. Under the pre-Task-5 scanner they were persisted as
  flagged `media_files` rows; the database CHECK added ahead of this task
  (`media_files_has_parent`) forbids that entirely, so they are persisted as
  `ImportCandidate` rows instead -- classified via `parsed_info`, never
  promoted, even when their anchor folder's match is confident enough that a
  regular file would have promoted (`FileIngest`'s extras-review-only
  override, pinned directly in `library_scanner_ingest_test.exs`).
  """
  # Touches the filesystem and the scanner, so no async.
  use Mydia.DataCase, async: false

  alias Mydia.Jobs.LibraryScanner
  alias Mydia.Library.{ImportCandidate, MediaFile, ScanSummary, ScriptedMatcher}
  alias Mydia.Repo

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  defp scan(library_path, opts) do
    case LibraryScanner.scan_library_path(library_path, opts) do
      {:ok, %ScanSummary{}} -> :ok
      other -> other
    end
  end

  @tag :tmp_dir
  test "a flat movie folder promotes the feature and leaves its extras as review candidates",
       %{tmp_dir: tmp_dir} do
    movie =
      media_item_fixture(%{
        type: "movie",
        tmdb_id: String.to_integer(ScriptedMatcher.provider_id()),
        title: ScriptedMatcher.title(),
        year: ScriptedMatcher.year()
      })

    movie_dir = Path.join(tmp_dir, "Scripted Movie (1999)")
    File.mkdir_p!(movie_dir)

    # A feature plus two extras the filename layer catches, all sharing the
    # movie's own anchor folder -- BatchMatcher resolves the anchor once and
    # reuses that (confident) verdict for the extras too, which is exactly
    # what makes this scenario a real test of the review-only override
    # rather than of the extras simply never matching anything.
    File.write!(Path.join(movie_dir, "Scripted.Movie.1999.1080p.BluRay.mkv"), "feature")
    File.write!(Path.join(movie_dir, "Scripted.Movie.1999.featurette.mkv"), "extra")
    File.write!(Path.join(movie_dir, "Scripted.Movie.1999.trailer.mkv"), "trailer")

    library_path = library_path_fixture(%{path: tmp_dir, type: "movies", auto_import: true})
    assert :ok = scan(library_path, matcher: ScriptedMatcher)

    assert [media_file] = Repo.all(MediaFile)
    assert media_file.media_item_id == movie.id
    assert Path.basename(media_file.relative_path) == "Scripted.Movie.1999.1080p.BluRay.mkv"

    candidates = Repo.all(ImportCandidate)
    assert length(candidates) == 2

    by_name = Map.new(candidates, &{Path.basename(&1.relative_path), &1})
    assert Map.has_key?(by_name, "Scripted.Movie.1999.featurette.mkv")
    assert Map.has_key?(by_name, "Scripted.Movie.1999.trailer.mkv")

    # Both extras carry the anchor's confident match -- proving they were
    # kept out of media_files by the extras-review-only rule, not merely
    # because they never matched anything -- and both remain undismissed,
    # visible for a human to decide.
    assert Enum.all?(candidates, &(&1.provider_id == ScriptedMatcher.provider_id()))
    assert Enum.all?(candidates, &(&1.confidence == 0.95))
    assert Enum.all?(candidates, &is_nil(&1.dismissed_at))

    assert by_name["Scripted.Movie.1999.featurette.mkv"].parsed_info["is_extra"] == true
    assert by_name["Scripted.Movie.1999.trailer.mkv"].parsed_info["is_trailer"] == true
  end

  @tag :tmp_dir
  test "a Plex extras subfolder is classified and kept as a review candidate", %{
    tmp_dir: tmp_dir
  } do
    # "Deleted Scenes" is not a redundant release folder, so PathAnchor gives
    # it its own anchor separate from any movie folder above it -- this file
    # is matched on its own, and "NOMATCH" in the filename pins that match to
    # a deterministic no-match verdict rather than depending on title-string
    # scoring.
    scenes_dir = Path.join([tmp_dir, "Scripted Movie (1999)", "Deleted Scenes"])
    File.mkdir_p!(scenes_dir)
    File.write!(Path.join(scenes_dir, "NOMATCH.cut.mkv"), "extra")

    library_path = library_path_fixture(%{path: tmp_dir, type: "movies", auto_import: true})
    assert :ok = scan(library_path, matcher: ScriptedMatcher)

    assert Repo.aggregate(MediaFile, :count) == 0
    assert [candidate] = Repo.all(ImportCandidate)
    assert candidate.parsed_info["is_extra"] == true
    refute candidate.dismissed_at
  end
end
