defmodule Mydia.Library.ImportRunTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures
  import Mydia.SettingsFixtures

  alias Mydia.{Library, Repo}

  setup do
    %{library_path: library_path_fixture(), user: user_fixture()}
  end

  describe "create_import_run/1" do
    test "starts a run in the running state", %{library_path: lp, user: user} do
      assert {:ok, run} =
               Library.create_import_run(%{
                 library_path_id: lp.id,
                 user_id: user.id,
                 mode: :review
               })

      assert run.status == :running
      assert run.phase == :scanning
      assert run.files_discovered == 0
      assert run.started_at
    end

    test "rejects a second run for a path that already has one running", %{
      library_path: lp,
      user: user
    } do
      assert {:ok, _} =
               Library.create_import_run(%{
                 library_path_id: lp.id,
                 user_id: user.id,
                 mode: :review
               })

      assert {:error, changeset} =
               Library.create_import_run(%{
                 library_path_id: lp.id,
                 user_id: user.id,
                 mode: :review
               })

      assert "already has a running import" in errors_on(changeset).library_path_id
    end

    test "allows a new run once the previous one stopped", %{library_path: lp, user: user} do
      {:ok, first} =
        Library.create_import_run(%{library_path_id: lp.id, user_id: user.id, mode: :review})

      {:ok, _} = Library.update_import_run(first, %{status: :stopped})

      assert {:ok, _second} =
               Library.create_import_run(%{
                 library_path_id: lp.id,
                 user_id: user.id,
                 mode: :unattended
               })
    end
  end

  describe "request_import_run_stop/1" do
    test "moves a running run to stopping", %{library_path: lp, user: user} do
      {:ok, run} =
        Library.create_import_run(%{library_path_id: lp.id, user_id: user.id, mode: :review})

      assert {:ok, stopping} = Library.request_import_run_stop(run)
      assert stopping.status == :stopping
      assert Library.import_run_stopping?(stopping)
    end

    test "re-reads from the database rather than trusting the passed struct", %{
      library_path: lp,
      user: user
    } do
      {:ok, run} =
        Library.create_import_run(%{library_path_id: lp.id, user_id: user.id, mode: :review})

      {:ok, _} = Library.request_import_run_stop(run)

      # `run` is the stale, pre-stop copy: its in-memory status is still :running.
      # This is exactly the shape the coordinator holds between chunks, so a
      # struct-only check would return false here and Stop would never take effect.
      assert run.status == :running
      assert Library.import_run_stopping?(run)
    end

    test "refuses to stop a run that already finished", %{library_path: lp, user: user} do
      {:ok, run} =
        Library.create_import_run(%{library_path_id: lp.id, user_id: user.id, mode: :review})

      {:ok, _} = Library.update_import_run(run, %{status: :done, phase: :finished})

      # `run` is the stale copy a Stop click holds when the coordinator reaches
      # :done in between the page rendering and the click landing. Without a
      # state-machine guard this writes :stopping over a terminal row, and
      # :stopping is active, so the path is locked out forever with no
      # coordinator left alive to advance it.
      assert {:error, _} = Library.request_import_run_stop(run)

      assert Library.get_import_run(run.id).status == :done
      refute Library.active_import_run(lp.id)
    end

    test "refuses to stop a run that already stopped", %{library_path: lp, user: user} do
      {:ok, run} =
        Library.create_import_run(%{library_path_id: lp.id, user_id: user.id, mode: :review})

      {:ok, _} = Library.update_import_run(run, %{status: :stopped, phase: :finished})

      assert {:error, _} = Library.request_import_run_stop(run)
      assert Library.get_import_run(run.id).status == :stopped
    end
  end

  describe "active_import_run/1" do
    test "finds the running run for a path", %{library_path: lp, user: user} do
      {:ok, run} =
        Library.create_import_run(%{library_path_id: lp.id, user_id: user.id, mode: :review})

      assert Library.active_import_run(lp.id).id == run.id
    end

    test "treats a stopping run as still active", %{library_path: lp, user: user} do
      {:ok, run} =
        Library.create_import_run(%{library_path_id: lp.id, user_id: user.id, mode: :review})

      {:ok, _} = Library.request_import_run_stop(run)

      assert Library.active_import_run(lp.id).id == run.id
    end

    test "returns nil once the run finished", %{library_path: lp, user: user} do
      {:ok, run} =
        Library.create_import_run(%{library_path_id: lp.id, user_id: user.id, mode: :review})

      {:ok, _} = Library.update_import_run(run, %{status: :done, phase: :finished})

      refute Library.active_import_run(lp.id)
    end
  end

  describe "last_import_run/1" do
    test "returns nil when the path has never had a run", %{library_path: lp} do
      refute Library.last_import_run(lp.id)
    end

    test "returns a terminal run, unlike active_import_run/1", %{library_path: lp, user: user} do
      {:ok, run} =
        Library.create_import_run(%{library_path_id: lp.id, user_id: user.id, mode: :review})

      {:ok, _} =
        Library.update_import_run(run, %{status: :failed, phase: :finished, error: "boom"})

      assert Library.last_import_run(lp.id).id == run.id
    end

    test "prefers the newer of two runs for the same path", %{library_path: lp, user: user} do
      {:ok, first} =
        Library.create_import_run(%{library_path_id: lp.id, user_id: user.id, mode: :review})

      {:ok, _} = Library.update_import_run(first, %{status: :done, phase: :finished})

      # import_runs.inserted_at is second-resolution (timestamps(type:
      # :utc_datetime)), so two runs created back-to-back in the same test
      # can tie on it. Backdating `first` deterministically establishes
      # "second is newer" without a real sleep, which would just make this
      # test slow rather than reliable (a tie could still land either way
      # depending on the clock).
      backdated = DateTime.add(first.inserted_at, -5, :second)
      {:ok, _} = first |> Ecto.Changeset.change(inserted_at: backdated) |> Repo.update()

      {:ok, second} =
        Library.create_import_run(%{library_path_id: lp.id, user_id: user.id, mode: :unattended})

      {:ok, _} = Library.update_import_run(second, %{status: :done, phase: :finished})

      assert Library.last_import_run(lp.id).id == second.id
    end
  end
end
