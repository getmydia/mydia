defmodule Mydia.Jobs.ImportRunReconcileTest do
  @moduledoc """
  Boot reconciliation for runs that were in flight when the node went away.

  Every fixture here carries an Oban job row, because production never has a
  run without one: `MydiaWeb.ImportMediaLive.Index` inserts the coordinator job
  in the same handler that creates the run, and `Oban.Plugins.Pruner` never
  prunes a job that is still `executing`. A reconciliation test whose fixture
  is "a run with no job at all" is testing a state the product cannot reach.

  The state that matters is `executing`. Without `Oban.Plugins.Lifeline` (which
  cannot be used here: `rescue_after` runs from `attempted_at`, and a real
  import runs for hours without checkpointing) nothing ever moves a job out of
  `executing` when the node dies. `Engine.shutdown/2` only sets `paused: true`.
  So `executing` is the normal shape of the crash being recovered from, not
  evidence that a worker is on it.
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

  # The node name Oban stamps into `attempted_by`. Derived the same way Oban
  # derives it rather than hardcoded, so this stays correct whether or not the
  # test VM happens to be distributed.
  defp this_node, do: Oban.Config.node_name()

  defp insert_job(run_id, state, attempted_by \\ nil) do
    changes =
      case attempted_by do
        nil -> [state: state]
        by -> [state: state, attempted_by: by, attempted_at: DateTime.utc_now()]
      end

    %{"import_run_id" => run_id}
    |> Oban.Job.new(worker: ImportRunJob, queue: :imports)
    |> Ecto.Changeset.change(changes)
    |> Repo.insert!()
  end

  # A run exactly as a killed node leaves it: the row still active, and its
  # coordinator job still `executing`, stamped with this node's name because
  # this node is the one that died.
  defp interrupted_run(lp, user, status) do
    {:ok, run} =
      Library.create_import_run(%{library_path_id: lp.id, user_id: user.id, mode: :review})

    run =
      if status == :running do
        run
      else
        # Written straight through Ecto: a crash leaves states behind that the
        # legal-transition guard would refuse, which is the point.
        run |> Ecto.Changeset.change(status: status) |> Repo.update!()
      end

    insert_job(run.id, "executing", [this_node()])

    run
  end

  describe "a run whose job is still executing on this node" do
    test "is marked failed when it was running", %{library_path: lp, user: user} do
      run = interrupted_run(lp, user, :running)

      assert {:ok, 1} = ImportRunJob.reconcile_interrupted_runs()

      reconciled = Library.get_import_run(run.id)
      assert reconciled.status == :failed
      assert reconciled.phase == :finished
      assert reconciled.error =~ "interrupted"
    end

    test "is marked stopped when it was already draining", %{library_path: lp, user: user} do
      run = interrupted_run(lp, user, :stopping)

      assert {:ok, 1} = ImportRunJob.reconcile_interrupted_runs()

      assert Library.get_import_run(run.id).status == :stopped
    end

    test "releases the library path so a new run can start", %{library_path: lp, user: user} do
      _run = interrupted_run(lp, user, :running)

      # Before reconciliation the partial unique index refuses a second run,
      # and nothing in the product could ever clear the first one.
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

    test "is reconciled when the job carries no attempted_by at all", %{
      library_path: lp,
      user: user
    } do
      {:ok, run} =
        Library.create_import_run(%{library_path_id: lp.id, user_id: user.id, mode: :review})

      insert_job(run.id, "executing")

      assert {:ok, 1} = ImportRunJob.reconcile_interrupted_runs()
      assert Library.get_import_run(run.id).status == :failed
    end
  end

  describe "runs that must be left alone" do
    test "a job executing on a different node", %{library_path: lp, user: user} do
      {:ok, run} =
        Library.create_import_run(%{library_path_id: lp.id, user_id: user.id, mode: :review})

      insert_job(run.id, "executing", ["some-other-host", Ecto.UUID.generate()])

      # This node's reconciler runs before this node's Oban starts, so a local
      # `executing` row is provably stale. Another node's is provably not.
      assert {:ok, 0} = ImportRunJob.reconcile_interrupted_runs()
      assert Library.get_import_run(run.id).status == :running
    end

    for state <- ~w(available retryable scheduled) do
      test "a job still queued as #{state}", %{library_path: lp, user: user} do
        {:ok, run} =
          Library.create_import_run(%{library_path_id: lp.id, user_id: user.id, mode: :review})

        insert_job(run.id, unquote(state))

        assert {:ok, 0} = ImportRunJob.reconcile_interrupted_runs()
        assert Library.get_import_run(run.id).status == :running
      end
    end

    test "a terminal run", %{library_path: lp, user: user} do
      {:ok, run} =
        Library.create_import_run(%{library_path_id: lp.id, user_id: user.id, mode: :review})

      run |> Ecto.Changeset.change(status: :done) |> Repo.update!()
      insert_job(run.id, "completed")

      assert {:ok, 0} = ImportRunJob.reconcile_interrupted_runs()
      assert Library.get_import_run(run.id).status == :done
    end
  end

  test "a completed job does not keep an active run alive", %{library_path: lp, user: user} do
    {:ok, run} =
      Library.create_import_run(%{library_path_id: lp.id, user_id: user.id, mode: :review})

    insert_job(run.id, "completed", [this_node()])

    assert {:ok, 1} = ImportRunJob.reconcile_interrupted_runs()
    assert Library.get_import_run(run.id).status == :failed
  end

  describe "the supervision child" do
    test "runs the sweep and then gets out of the way", %{library_path: lp, user: user} do
      run = interrupted_run(lp, user, :running)

      # :ignore is what keeps this from lingering as a process, and is why it
      # can sit in the children list between Ecto.Migrator and the Oban child
      # without becoming something to supervise. See the module doc: that
      # position is the entire discriminator for a stale `executing` row.
      assert :ignore = Mydia.Jobs.ImportRunReconciler.start_link([])

      assert Library.get_import_run(run.id).status == :failed
    end
  end
end
