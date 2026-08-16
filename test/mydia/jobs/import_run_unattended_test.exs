defmodule Mydia.Jobs.ImportRunUnattendedTest do
  @moduledoc """
  The coordinator's link path, exercised end to end.

  Every other coordinator test stubs the relay with an empty result set, so
  until this file existed nothing had ever run `Jobs.ImportRun`'s
  `:create_items` policy against a real (non-empty) match. That gap is what let
  a non-terminating `match_loop/4` survive to final review: a file that
  `MetadataEnricher.enrich/2` reports `{:ok, item}` for without actually
  associating anything used to come back as `{:linked, _}`, keeping the file in
  the unmatched set forever.

  `Mydia.MetadataStub` is used rather than Bypass because the link path fans
  out over search, fetch_by_id and fetch_season, and the stub catalog is
  self-consistent across all three (every id it returns is resolvable). It
  mutates the global `Provider.Registry` Agent, hence `async: false`.
  """
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.MetadataStub
  import Mydia.SettingsFixtures

  alias Mydia.Jobs.ImportRun, as: ImportRunJob
  alias Mydia.Library
  alias Mydia.Media
  alias Mydia.MetadataStubProvider
  alias Mydia.Repo

  setup :setup_metadata_stub

  # A hard ceiling on the match phase. Before the FileIngest contract fix,
  # `match_loop/4` spun forever on a file it believed it had linked, so a bare
  # call here would hang the whole suite instead of failing. Running it in a
  # task and yielding turns "never terminates" into a fast, legible failure.
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

      # Linked means out of the inbox: the candidate rows are deleted, which is
      # also what keeps the file out of the unmatched set on a resumed run.
      assert Library.list_match_candidates(file.id) == []
      assert Library.list_unmatched_media_file_paths(lp.id, 100) == []
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
      assert Library.list_unmatched_media_file_paths(lp.id, 100) == []
    end
  end

  describe "a TV file whose episode does not exist" do
    # This is the discriminating case for the non-termination defect.
    # `MetadataEnricher.enrich/2` returns `{:ok, media_item}` here: the show
    # was found and created, only the target episode row does not exist
    # (a special, an out of range number, absolute anime numbering). Nothing
    # was associated, so reporting it as linked leaves the file with no parent
    # AND no candidate, which puts it straight back into the next chunk.
    test "is not reported as linked, stays in the inbox, and the phase still terminates" do
      title = MetadataStubProvider.series_title()

      {lp, run} =
        library_with("series", [Path.join([title, "Season 01", "#{title} - S01E99.mkv"])])

      assert :ok = match_within(run)

      assert [file] = Library.list_media_files(library_path_id: lp.id)
      assert is_nil(file.episode_id)
      assert is_nil(file.media_item_id)

      assert Library.get_import_run(run.id).files_linked == 0

      # The file must remain visible somewhere. A candidate row is what keeps
      # it in the inbox and out of the unmatched set, so the loop can finish.
      assert [candidate] = Library.list_match_candidates(file.id)
      assert candidate.last_error =~ title
      assert Library.count_inbox_files(library_path_id: lp.id) == 1
      assert Library.list_unmatched_media_file_paths(lp.id, 100) == []
    end
  end
end
