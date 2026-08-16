defmodule Mydia.Jobs.ImportRunReconcileTest do
  @moduledoc """
  Boot reconciliation for runs that were in flight when the node went away.

  Nothing but the coordinator itself ever moves a run out of `:running` or
  `:stopping`, and `Oban.Plugins.Lifeline` is deliberately not configured (its
  `rescue_after` is measured from `attempted_at`, and this job legitimately
  runs for hours without checkpointing, so any window short enough to rescue a
  crashed run would also duplicate a healthy one). A container restart during
  an import therefore used to leave the row active forever, which locks that
  library path out of ever being imported again.
  """
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Jobs.ImportRun, as: ImportRunJob
  alias Mydia.Library
  alias Mydia.Repo

  setup do
    %{library_path: library_path_fixture(), user: user_fixture()}
  end

  defp start_run(lp, user, status) do
    {:ok, run} =
      Library.create_import_run(%{library_path_id: lp.id, user_id: user.id, mode: :review})

    if status == :running do
      run
    else
      # Written straight through Ecto rather than via update_import_run/2: the
      # legal-transition guard is what this file's siblings cover, and some of
      # these fixtures are deliberately illegal states left behind by a crash.
      run |> Ecto.Changeset.change(status: status) |> Repo.update!()
    end
  end

  defp insert_job(run_id, state) do
    %{"import_run_id" => run_id}
    |> Oban.Job.new(worker: ImportRunJob, queue: :imports)
    |> Ecto.Changeset.put_change(:state, state)
    |> Repo.insert!()
  end

  test "marks an interrupted running run as failed", %{library_path: lp, user: user} do
    run = start_run(lp, user, :running)

    assert {:ok, 1} = ImportRunJob.reconcile_interrupted_runs()

    reconciled = Library.get_import_run(run.id)
    assert reconciled.status == :failed
    assert reconciled.phase == :finished
    assert reconciled.error =~ "interrupted"
  end

  test "marks an interrupted stopping run as stopped", %{library_path: lp, user: user} do
    run = start_run(lp, user, :stopping)

    assert {:ok, 1} = ImportRunJob.reconcile_interrupted_runs()

    assert Library.get_import_run(run.id).status == :stopped
  end

  test "releases the library path so a new run can start", %{library_path: lp, user: user} do
    _run = start_run(lp, user, :running)

    # The whole point: before reconciliation the partial unique index refuses
    # a second run, and nothing in the product could ever clear the first one.
    assert {:error, _} =
             Library.create_import_run(%{
               library_path_id: lp.id,
               user_id: user.id,
               mode: :review
             })

    {:ok, _} = ImportRunJob.reconcile_interrupted_runs()

    assert {:ok, _} =
             Library.create_import_run(%{
               library_path_id: lp.id,
               user_id: user.id,
               mode: :review
             })
  end

  for state <- ~w(executing available retryable scheduled) do
    test "leaves a run alone while its job is still #{state}", %{library_path: lp, user: user} do
      run = start_run(lp, user, :running)
      insert_job(run.id, unquote(state))

      assert {:ok, 0} = ImportRunJob.reconcile_interrupted_runs()
      assert Library.get_import_run(run.id).status == :running
    end
  end

  test "ignores a completed job for the same run", %{library_path: lp, user: user} do
    run = start_run(lp, user, :running)
    insert_job(run.id, "completed")

    assert {:ok, 1} = ImportRunJob.reconcile_interrupted_runs()
    assert Library.get_import_run(run.id).status == :failed
  end

  test "leaves terminal runs untouched", %{library_path: lp, user: user} do
    run = start_run(lp, user, :done)

    assert {:ok, 0} = ImportRunJob.reconcile_interrupted_runs()
    assert Library.get_import_run(run.id).status == :done
  end
end
