defmodule Mydia.Jobs.ImportRunUnattendedTest do
  @moduledoc """
  The coordinator's promotion path, exercised end to end.

  Every other coordinator test stubs the relay with an empty result set, so
  until this file existed nothing had ever run `Jobs.ImportRun`'s
  `:unattended` policy against a real (non-empty) match. That gap is what let
  a non-terminating `match_loop/4` survive to final review: a candidate that
  `MetadataEnricher.enrich/2` reports `{:ok, item}` for without actually
  associating anything used to come back as `{:promoted, _}`, keeping the
  candidate in the outstanding set forever.

  `Mydia.MetadataStub` is used rather than Bypass because the promotion path
  fans out over search, fetch_by_id and fetch_season, and the stub catalog is
  self-consistent across all three (every id it returns is resolvable). It
  mutates the global `Provider.Registry` Agent, hence `async: false`.
  """
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.MetadataStub
  import Mydia.SettingsFixtures

  alias Mydia.ImportCandidates
  alias Mydia.Jobs.ImportRun, as: ImportRunJob
  alias Mydia.Library
  alias Mydia.Library.ImportCandidate
  alias Mydia.Media
  alias Mydia.MetadataStubProvider
  alias Mydia.Repo

  setup :setup_metadata_stub

  # A hard ceiling on the match phase. Before the FileIngest contract fix,
  # `match_loop/4` spun forever on a candidate it believed it had promoted, so
  # a bare call here would hang the whole suite instead of failing. Running it
  # in a task and yielding turns "never terminates" into a fast, legible
  # failure.
  defp match_within(run, timeout \\ 30_000) do
    task = Task.async(fn -> ImportRunJob.run_match_phase(Library.get_import_run(run.id)) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        flunk("run_match_phase/2 did not terminate within #{timeout}ms")
    end
  end

  defp library_with(type, files) do
    dir = Path.join(System.tmp_dir!(), "import_unattended_#{System.unique_integer([:positive])}")

    Enum.each(files, fn relative ->
      full = Path.join(dir, relative)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, "x")
    end)

    on_exit(fn -> File.rm_rf!(dir) end)

    library_path = library_path_fixture(%{path: dir, type: type})

    {:ok, run} =
      Library.create_import_run(%{
        library_path_id: library_path.id,
        user_id: user_fixture().id,
        mode: :unattended
      })

    :ok = ImportRunJob.run_scan_phase(Library.get_import_run(run.id))

    {library_path, Library.get_import_run(run.id)}
  end

  describe "unattended mode links a confident movie match" do
    test "creates the media item, associates the file, and counts it" do
      {lp, run} = library_with("movies", ["#{MetadataStubProvider.movie_title()} (1999).mkv"])

      assert Library.get_import_run(run.id).files_discovered == 1

      assert :ok = match_within(run)

      assert Library.get_import_run(run.id).files_matched == 1

      assert [item] = Media.list_media_items() |> Enum.filter(&(&1.type == "movie"))
      assert item.title == MetadataStubProvider.movie_title()

      assert [file] = Library.list_media_files(library_path_id: lp.id)
      assert file.media_item_id == item.id

      assert Library.get_import_run(run.id).files_linked == 1

      # Promoted means out of the inbox: the candidate row is deleted, which
      # is also what keeps the file out of the outstanding set on a resumed
      # run.
      assert ImportCandidates.get_by_path(lp.id, file.relative_path) == nil
      assert ImportCandidates.count_outstanding(lp.id) == 0
    end
  end

  describe "unattended mode links a confident TV match" do
    test "sets episode_id on the file rather than media_item_id" do
      title = MetadataStubProvider.series_title()

      {lp, run} =
        library_with("series", [Path.join([title, "Season 01", "#{title} - S01E01.mkv"])])

      assert :ok = match_within(run)

      assert [file] = Library.list_media_files(library_path_id: lp.id)

      # A TV media_file hangs off the episode, not the show: media_item_id
      # stays nil on purpose, so asserting on it alone would silently pass for
      # a file that was never associated at all.
      refute is_nil(file.episode_id)

      episode = Repo.get!(Media.Episode, file.episode_id)
      assert episode.season_number == 1
      assert episode.episode_number == 1

      assert Library.get_import_run(run.id).files_linked == 1
      assert ImportCandidates.count_outstanding(lp.id) == 0
    end
  end

  describe "a TV file whose episode does not exist" do
    # This is the discriminating case for the non-termination defect.
    # `MetadataEnricher.enrich/2` returns `{:ok, media_item}` here: the show
    # was found and created, only the target episode row does not exist
    # (a special, an out of range number, absolute anime numbering). Nothing
    # was associated, so reporting it as promoted leaves the candidate with
    # no parent AND unresolved, which puts it straight back into the next
    # chunk.
    test "is not reported as linked, stays in the inbox, and the phase still terminates" do
      title = MetadataStubProvider.series_title()

      {lp, run} =
        library_with("series", [Path.join([title, "Season 01", "#{title} - S01E99.mkv"])])

      assert :ok = match_within(run)

      assert Library.list_media_files(library_path_id: lp.id) == []
      assert Library.get_import_run(run.id).files_linked == 0

      # The candidate must remain visible somewhere: it is what keeps the
      # file in the inbox and out of the outstanding set, so the loop can
      # finish. `EpisodeMinter.mint/4` refuses S01E99 as an implausible
      # episode number for this show rather than minting it, so
      # `CandidatePromotion.promote_group/3` fails and `FileIngest` records
      # that failure onto the candidate instead of promoting it.
      relative_path = Path.join([title, "Season 01", "#{title} - S01E99.mkv"])
      candidate = ImportCandidates.get_by_path(lp.id, relative_path)
      refute is_nil(candidate)
      assert candidate.last_error =~ "implausible"

      assert Repo.aggregate(ImportCandidate, :count) == 1
      assert ImportCandidates.count_outstanding(lp.id) == 0
    end
  end
end
