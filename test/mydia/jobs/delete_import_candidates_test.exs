defmodule Mydia.Jobs.DeleteImportCandidatesTest do
  use Mydia.DataCase, async: false

  import Ecto.Query
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Jobs.DeleteImportCandidates
  alias Mydia.Library.ImportCandidate
  alias Mydia.Repo

  setup do
    root =
      Path.join(System.tmp_dir!(), "mydia_delete_job_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{lp: library_path_fixture(%{type: "series", path: root})}
  end

  defp queue_for_delete(lp, relative_path) do
    candidate = import_candidate_fixture(%{library_path_id: lp.id, relative_path: relative_path})

    Repo.update_all(from(c in ImportCandidate, where: c.id == ^candidate.id),
      set: [queued_op: "delete"]
    )

    candidate
  end

  test "deletes the queued files for its library path", %{lp: lp} do
    File.write!(Path.join(lp.path, "stray.mkv"), "data")
    candidate = queue_for_delete(lp, "stray.mkv")

    assert :ok = DeleteImportCandidates.perform(%Oban.Job{args: %{"library_path_id" => lp.id}})
    refute File.exists?(Path.join(lp.path, "stray.mkv"))
    refute Repo.get(ImportCandidate, candidate.id)
  end

  test "a file that cannot be removed does not fail the job", %{lp: lp} do
    File.mkdir_p!(Path.join(lp.path, "as-dir.mkv"))
    candidate = queue_for_delete(lp, "as-dir.mkv")

    assert :ok = DeleteImportCandidates.perform(%Oban.Job{args: %{"library_path_id" => lp.id}})
    assert Repo.reload!(candidate).queue_error =~ "Could not delete from disk"
  end
end
