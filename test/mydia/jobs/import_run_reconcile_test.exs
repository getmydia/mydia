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
    # A real, empty directory rather than the fixture's default phantom path.
    # One test below runs the coordinator against this library to prove it
    # refuses a terminal run, and that only means anything if the scan would
    # otherwise have succeeded and finished the run at :done.
    dir = Path.join(System.tmp_dir!(), "import_reconcile_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    %{
      library_path: library_path_fixture(%{path: dir, type: "movies"}),
      user: user_fixture()
    }
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
      # without becoming something to supervise.
      assert :ignore = Mydia.Jobs.ImportRunReconciler.start_link([])

      assert Library.get_import_run(run.id).status == :failed
    end

    test "starts after the migrator and before Oban" do
      # This ordering IS the correctness argument for treating a lingering
      # `executing` job row as stale (see the reconciler's moduledoc), and it
      # lives in a list nothing else asserts on. Moving the child below
      # oban_children/1 would leave every other test in this file green while
      # making live_job?/3 release healthy, just-started jobs.
      #
      # Oban is forced on via the argument rather than by touching the global
      # env: the test environment runs `testing: :manual`, so oban_children/1
      # returns [] and the assertion below would be vacuously true.
      children = Mydia.Application.children(queues: [imports: 1])

      migrator = Enum.find_index(children, &match?({Ecto.Migrator, _}, &1))
      reconciler = Enum.find_index(children, &(&1 == Mydia.Jobs.ImportRunReconciler))
      oban = Enum.find_index(children, &match?({Oban, _}, &1))

      assert migrator, "expected an Ecto.Migrator child"
      assert reconciler, "expected a Mydia.Jobs.ImportRunReconciler child"
      assert oban, "expected forcing an Oban config to produce an Oban child"

      # After the migrator because it queries import_runs, before Oban because
      # a queue that has started can legitimately own an `executing` row.
      assert migrator < reconciler
      assert reconciler < oban
    end
  end

  describe "the pre-existing stale-job sweep" do
    # Mydia.Application runs Mydia.Jobs.reset_stale_executing_jobs/1 later in
    # the same boot, and it re-queues ANY job that has been `executing` for
    # over an hour. An import that ran for hours before the crash is exactly
    # that job, so this is the common case for this feature, not the tail.
    setup %{library_path: lp, user: user} do
      run = interrupted_run(lp, user, :running)

      job =
        Repo.one!(from(j in Oban.Job, where: j.worker == ^inspect(ImportRunJob)))
        |> Ecto.Changeset.change(attempted_at: DateTime.add(DateTime.utc_now(), -2, :hour))
        |> Repo.update!()

      %{run: run, job: job}
    end

    test "cannot re-queue a job this reconciler already retired", %{job: job} do
      assert {:ok, 1} = ImportRunJob.reconcile_interrupted_runs()

      assert {:ok, _} = Mydia.Jobs.reset_stale_executing_jobs()

      # The reconciler's verdict has to survive the sweep that runs after it.
      # Left `executing`, this row goes back to `available` with attempt 1 of
      # 3 and Oban runs the coordinator again, against a run already marked
      # failed, while the user is being told to start a new one.
      refute Repo.get!(Oban.Job, job.id).state in ~w(available scheduled executing retryable)
    end

    test "leaves no way for two coordinators to work one library path", %{
      library_path: lp,
      user: user,
      job: job
    } do
      {:ok, 1} = ImportRunJob.reconcile_interrupted_runs()
      {:ok, _} = Mydia.Jobs.reset_stale_executing_jobs()

      # The reconciler's own error text tells the user to start again, and
      # :failed is not active, so create_import_run/1 rightly succeeds. The
      # partial unique index guards active import_runs rows, not Oban jobs, so
      # the retired job is the only thing standing between that and two
      # coordinators scanning the same tree at once.
      {:ok, fresh} =
        Library.create_import_run(%{library_path_id: lp.id, user_id: user.id, mode: :review})

      new_job = insert_job(fresh.id, "available")

      runnable =
        from(j in Oban.Job,
          where: j.worker == ^inspect(ImportRunJob),
          where: j.state in ~w(available scheduled executing retryable)
        )
        |> Repo.all()

      assert Enum.map(runnable, & &1.id) == [new_job.id]
      refute job.id in Enum.map(runnable, & &1.id)
    end

    test "a retired job that runs anyway does not execute against a terminal run", %{run: run} do
      {:ok, 1} = ImportRunJob.reconcile_interrupted_runs()

      # Defence in depth for the same collision. The library path points at a
      # real, empty directory, so without a terminal check perform/1 scans it
      # happily, matches nothing, and finishes the run at :done, overwriting
      # the interruption verdict with a success the user never got.
      assert :ok =
               ImportRunJob.perform(%Oban.Job{
                 args: %{"import_run_id" => run.id},
                 attempt: 1,
                 max_attempts: 3
               })

      reconciled = Library.get_import_run(run.id)
      assert reconciled.status == :failed
      assert reconciled.error =~ "interrupted"
    end
  end
end
