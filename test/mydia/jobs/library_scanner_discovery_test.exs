defmodule Mydia.Jobs.LibraryScannerDiscoveryTest do
  @moduledoc """
  Pins the auto_import gate itself: a scheduled scan always maintains known
  files and reaps missing candidates, and only discovers/matches unknown
  paths when the library path has `auto_import: true`.

  `Mydia.Library.RaisingMatcher` proves the `auto_import: false` branch never
  reaches matching at all -- not "matches and ignores the result", but never
  calls a matcher in the first place. `Mydia.Library.ScriptedMatcher` gives
  the `auto_import: true` branch deterministic confident/ambiguous/no-match
  outcomes with no relay call anywhere in the chain: a confident verdict
  links to a `media_item_fixture` created locally with the same provider id,
  which `MetadataEnricher` finds and reuses (a just-created item is inside
  its "recently enriched" window) instead of fetching, so promotion runs for
  real through `Mydia.Library.CandidatePromotion` without a network seam.
  """
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Jobs.LibraryScanner
  alias Mydia.Library
  alias Mydia.Library.{ImportCandidate, MediaFile, RaisingMatcher, ScriptedMatcher}
  alias Mydia.Repo

  @moduletag :tmp_dir

  defp scan(library_path, opts) do
    case LibraryScanner.scan_library_path(library_path, opts) do
      {:ok, %Library.ScanSummary{}} -> :ok
      other -> other
    end
  end

  defp owned_file_on_disk(library_path, opts \\ []) do
    content = Keyword.get(opts, :content, "original")

    relative_path =
      Keyword.get(opts, :relative_path, "Owned #{System.unique_integer([:positive])}.mkv")

    absolute_path = Path.join(library_path.path, relative_path)
    File.mkdir_p!(Path.dirname(absolute_path))
    File.write!(absolute_path, content)

    media_item = media_item_fixture(%{type: "movie"})

    {:ok, media_file} =
      Library.create_media_file(%{
        media_item_id: media_item.id,
        library_path_id: library_path.id,
        relative_path: relative_path,
        size: byte_size(content),
        verified_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    %{media_file: media_file, absolute_path: absolute_path}
  end

  describe "auto_import: false" do
    test "ignores an unknown path without parsing or relay work", %{tmp_dir: tmp_dir} do
      lp = library_path_fixture(%{path: tmp_dir, type: "movies", auto_import: false})
      File.write!(Path.join(tmp_dir, "Unknown.2026.mkv"), "x")

      assert :ok = scan(lp, matcher: RaisingMatcher)
      assert Repo.aggregate(MediaFile, :count) == 0
      assert Repo.aggregate(ImportCandidate, :count) == 0
    end

    test "still trashes a known file that disappeared from disk", %{tmp_dir: tmp_dir} do
      lp = library_path_fixture(%{path: tmp_dir, type: "movies", auto_import: false})
      owned = owned_file_on_disk(lp)
      File.rm!(owned.absolute_path)

      assert :ok = scan(lp, matcher: RaisingMatcher)
      assert Repo.reload!(owned.media_file).trashed_at
    end
  end

  describe "both modes" do
    for auto_import <- [false, true] do
      test "maintain known files and reap missing candidates (auto_import: #{auto_import})", %{
        tmp_dir: tmp_dir
      } do
        lp =
          library_path_fixture(%{
            path: tmp_dir,
            type: "movies",
            auto_import: unquote(auto_import)
          })

        owned = owned_file_on_disk(lp)
        stale = import_candidate_fixture(library_path_id: lp.id, relative_path: "gone.mkv")
        File.write!(owned.absolute_path, "changed")

        assert :ok = scan(lp, matcher: RaisingMatcher)
        assert Repo.reload!(owned.media_file).size == File.stat!(owned.absolute_path).size
        refute Repo.get(ImportCandidate, stale.id)
      end

      test "adopt a sidecar sitting beside an existing owned file (auto_import: #{auto_import})",
           %{tmp_dir: tmp_dir} do
        lp =
          library_path_fixture(%{
            path: tmp_dir,
            type: "movies",
            auto_import: unquote(auto_import)
          })

        owned = owned_file_on_disk(lp, relative_path: "movie.mkv")

        File.write!(Path.join(tmp_dir, "movie.en.srt"), """
        1
        00:00:01,000 --> 00:00:02,000
        Hello.
        """)

        assert :ok = scan(lp, matcher: RaisingMatcher)

        assert [subtitle] = Mydia.Subtitles.list_subtitles(owned.media_file.id)
        assert subtitle.origin == "sidecar"
        assert subtitle.language == "en"
      end
    end
  end

  describe "auto_import: true discovery" do
    test "a confident match promotes into an owned media file", %{tmp_dir: tmp_dir} do
      movie =
        media_item_fixture(%{
          type: "movie",
          tmdb_id: String.to_integer(ScriptedMatcher.provider_id()),
          title: ScriptedMatcher.title(),
          year: ScriptedMatcher.year()
        })

      lp = library_path_fixture(%{path: tmp_dir, type: "movies", auto_import: true})
      dir = Path.join(tmp_dir, "Confident Movie (1999)")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "Confident.Movie.1999.1080p.mkv"), "video")

      assert :ok = scan(lp, matcher: ScriptedMatcher)

      assert Repo.aggregate(ImportCandidate, :count) == 0
      assert [media_file] = Repo.all(MediaFile)
      assert media_file.media_item_id == movie.id
    end

    test "an ambiguous match stays a review candidate, not promoted", %{tmp_dir: tmp_dir} do
      lp = library_path_fixture(%{path: tmp_dir, type: "movies", auto_import: true})
      dir = Path.join(tmp_dir, "Ambiguous Movie (1999)")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "AMBIGUOUS.Movie.1999.1080p.mkv"), "video")

      assert :ok = scan(lp, matcher: ScriptedMatcher)

      assert Repo.aggregate(MediaFile, :count) == 0
      assert [candidate] = Repo.all(ImportCandidate)
      assert candidate.provider_id == ScriptedMatcher.provider_id()
      assert candidate.confidence == 0.5
      refute candidate.dismissed_at
    end

    test "a failed match leaves retry state on the candidate", %{tmp_dir: tmp_dir} do
      lp = library_path_fixture(%{path: tmp_dir, type: "movies", auto_import: true})
      dir = Path.join(tmp_dir, "NOMATCH Movie (1999)")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "NOMATCH.Movie.1999.1080p.mkv"), "video")

      assert :ok = scan(lp, matcher: ScriptedMatcher)

      assert Repo.aggregate(MediaFile, :count) == 0
      assert [candidate] = Repo.all(ImportCandidate)
      refute candidate.provider_id
      assert candidate.attempts == 1
      assert candidate.last_error == "no_match"
      assert candidate.next_retry_at
    end

    test "a changed candidate's stale match is cleared and re-matched", %{tmp_dir: tmp_dir} do
      lp = library_path_fixture(%{path: tmp_dir, type: "movies", auto_import: true})
      relative_path = "Ambiguous Movie (1999)/AMBIGUOUS.Movie.1999.1080p.mkv"
      absolute_path = Path.join(tmp_dir, relative_path)
      File.mkdir_p!(Path.dirname(absolute_path))
      File.write!(absolute_path, "new content, different size than the stale candidate")

      stale =
        import_candidate_fixture(
          library_path_id: lp.id,
          relative_path: relative_path,
          size: 1,
          provider_id: "999999",
          provider_type: "tmdb",
          title: "Stale Match",
          confidence: 1.0
        )

      assert :ok = scan(lp, matcher: ScriptedMatcher)

      reloaded = Repo.get!(ImportCandidate, stale.id)
      assert reloaded.provider_id == ScriptedMatcher.provider_id()
      assert reloaded.confidence == 0.5
      refute reloaded.title == "Stale Match"
    end

    test "a dismissed candidate's dismissal survives a rescan and is never re-matched", %{
      tmp_dir: tmp_dir
    } do
      lp = library_path_fixture(%{path: tmp_dir, type: "movies", auto_import: true})
      relative_path = "Dismissed Movie (1999)/Dismissed.Movie.1999.1080p.mkv"
      absolute_path = Path.join(tmp_dir, relative_path)
      File.mkdir_p!(Path.dirname(absolute_path))
      content = "same size before and after"
      File.write!(absolute_path, content)

      dismissed =
        import_candidate_fixture(
          library_path_id: lp.id,
          relative_path: relative_path,
          size: byte_size(content),
          dismissed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        )

      assert :ok = scan(lp, matcher: ScriptedMatcher)

      reloaded = Repo.get!(ImportCandidate, dismissed.id)
      assert reloaded.dismissed_at
      refute reloaded.provider_id
      assert Repo.aggregate(MediaFile, :count) == 0
    end

    test "a deleted owned file is trashed even while discovery also runs", %{tmp_dir: tmp_dir} do
      lp = library_path_fixture(%{path: tmp_dir, type: "movies", auto_import: true})
      owned = owned_file_on_disk(lp)
      File.rm!(owned.absolute_path)

      dir = Path.join(tmp_dir, "NOMATCH Movie (1999)")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "NOMATCH.Movie.1999.1080p.mkv"), "video")

      assert :ok = scan(lp, matcher: ScriptedMatcher)
      assert Repo.reload!(owned.media_file).trashed_at
    end

    test "a dismissed candidate whose file content changed still has match state cleared and stays dismissed",
         %{tmp_dir: tmp_dir} do
      lp = library_path_fixture(%{path: tmp_dir, type: "movies", auto_import: true})
      relative_path = "Dismissed Changed (1999)/Dismissed.Changed.1999.1080p.mkv"
      absolute_path = Path.join(tmp_dir, relative_path)
      File.mkdir_p!(Path.dirname(absolute_path))
      File.write!(absolute_path, "new content, a different size than the dismissed candidate")

      dismissed =
        import_candidate_fixture(
          library_path_id: lp.id,
          relative_path: relative_path,
          size: 1,
          provider_id: "999999",
          provider_type: "tmdb",
          title: "Stale Dismissed Match",
          confidence: 1.0,
          dismissed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        )

      # Content-changed clearing must not depend on the outstanding sweep --
      # a dismissed candidate never enters it (ImportCandidates.outstanding/3
      # excludes dismissed rows), so ScriptedMatcher is never actually called
      # here either way. RaisingMatcher pins that this scenario truly cannot
      # reach a matcher, not merely that it happens not to today.
      assert :ok = scan(lp, matcher: RaisingMatcher)

      reloaded = Repo.get!(ImportCandidate, dismissed.id)
      assert reloaded.dismissed_at
      refute reloaded.provider_id
      refute reloaded.title == "Stale Dismissed Match"
      assert reloaded.confidence == nil
      assert Repo.aggregate(MediaFile, :count) == 0
    end
  end

  describe "library type compatibility" do
    test "a movie file in a series-only library makes no matcher call and creates nothing", %{
      tmp_dir: tmp_dir
    } do
      lp = library_path_fixture(%{path: tmp_dir, type: "series", auto_import: true})
      dir = Path.join(tmp_dir, "Confident Movie (1999)")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "Confident.Movie.1999.1080p.mkv"), "video")

      assert :ok = scan(lp, matcher: RaisingMatcher)

      assert Repo.aggregate(MediaFile, :count) == 0
      assert Repo.aggregate(ImportCandidate, :count) == 0
    end

    test "a TV-shaped file in a movies-only library makes no matcher call and creates nothing",
         %{tmp_dir: tmp_dir} do
      lp = library_path_fixture(%{path: tmp_dir, type: "movies", auto_import: true})
      dir = Path.join(tmp_dir, "Confident Show")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "Confident.Show.S01E01.1080p.mkv"), "video")

      assert :ok = scan(lp, matcher: RaisingMatcher)

      assert Repo.aggregate(MediaFile, :count) == 0
      assert Repo.aggregate(ImportCandidate, :count) == 0
    end

    test "a mixed library accepts both a movie and a TV-shaped file", %{tmp_dir: tmp_dir} do
      lp = library_path_fixture(%{path: tmp_dir, type: "mixed", auto_import: true})
      movie_dir = Path.join(tmp_dir, "AMBIGUOUS Movie (1999)")
      File.mkdir_p!(movie_dir)
      File.write!(Path.join(movie_dir, "AMBIGUOUS.Movie.1999.1080p.mkv"), "video")

      tv_dir = Path.join(tmp_dir, "AMBIGUOUS Show")
      File.mkdir_p!(tv_dir)
      File.write!(Path.join(tv_dir, "AMBIGUOUS.Show.S01E01.1080p.mkv"), "video")

      assert :ok = scan(lp, matcher: ScriptedMatcher)

      assert Repo.aggregate(ImportCandidate, :count) == 2
    end
  end
end
