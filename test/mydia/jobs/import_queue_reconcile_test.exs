defmodule Mydia.Jobs.ImportQueueReconcileTest do
  @moduledoc """
  Boot requeue of import queue drains stranded by a dead node.

  The drain jobs (accept, rematch, delete) are `executing` when the node dies
  and stay that way, because nothing rescues them. The candidates they were
  draining keep their `queued_op`, so without this the groups sit in Queued
  until the user returns them to review by hand.
  """
  use Mydia.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.ImportCandidates
  alias Mydia.Jobs.{ApplyImportCandidates, DeleteImportCandidates, RematchImportCandidates}
  alias Mydia.Jobs.ImportRun, as: ImportRunJob
  alias Mydia.Library.ImportCandidate
  alias Mydia.Repo

  @ops [
    {"accept", ApplyImportCandidates},
    {"rematch", RematchImportCandidates},
    {"delete", DeleteImportCandidates}
  ]

  setup do
    %{
      lp: library_path_fixture(%{type: "movies"}),
      other_lp: library_path_fixture(%{type: "movies"})
    }
  end

  defp this_node, do: Oban.Config.node_name()

  defp queue(lp, op, relative_path) do
    candidate = import_candidate_fixture(%{library_path_id: lp.id, relative_path: relative_path})

    Repo.update_all(from(c in ImportCandidate, where: c.id == ^candidate.id),
      set: [queued_op: op]
    )

    candidate
  end

  defp insert_job(worker, args, state, attempted_by \\ nil) do
    changes =
      case attempted_by do
        nil -> [state: state]
        by -> [state: state, attempted_by: by, attempted_at: DateTime.utc_now()]
      end

    args
    |> Oban.Job.new(worker: worker)
    |> Ecto.Changeset.change(changes)
    |> Repo.insert!()
  end

  defp drain_jobs(state) do
    workers = Enum.map(@ops, fn {_op, worker} -> inspect(worker) end)

    Repo.all(from(j in Oban.Job, where: j.worker in ^workers and j.state == ^state))
  end

  describe "stranded queued candidates" do
    for {op, worker} <- @ops do
      test "#{op} gets exactly one drain per library path", %{lp: lp, other_lp: other_lp} do
        queue(lp, unquote(op), "one.mkv")
        queue(lp, unquote(op), "two.mkv")
        queue(other_lp, unquote(op), "three.mkv")

        assert {:ok, %{retired: 0, enqueued: 2}} = ImportCandidates.requeue_stranded()

        jobs = drain_jobs("available")
        assert Enum.all?(jobs, &(&1.worker == inspect(unquote(worker))))

        assert Enum.sort(Enum.map(jobs, & &1.args["library_path_id"])) ==
                 Enum.sort([lp.id, other_lp.id])
      end
    end

    test "a library path queued under two ops gets two jobs", %{lp: lp} do
      queue(lp, "accept", "one.mkv")
      queue(lp, "delete", "two.mkv")

      assert {:ok, %{enqueued: 2}} = ImportCandidates.requeue_stranded()

      assert drain_jobs("available") |> Enum.map(& &1.worker) |> Enum.sort() ==
               Enum.sort([inspect(ApplyImportCandidates), inspect(DeleteImportCandidates)])
    end

    test "an unknown queued_op is skipped, not raised", %{lp: lp} do
      queue(lp, "bogus", "one.mkv")

      capture_log(fn ->
        assert {:ok, %{enqueued: 0}} = ImportCandidates.requeue_stranded()
      end)

      assert drain_jobs("available") == []
    end
  end

  describe "a drain that is already pending" do
    for state <- ~w(available scheduled retryable) do
      test "#{state} suppresses the insert", %{lp: lp} do
        queue(lp, "accept", "one.mkv")
        job = insert_job(ApplyImportCandidates, %{"library_path_id" => lp.id}, unquote(state))

        assert {:ok, %{enqueued: 0}} = ImportCandidates.requeue_stranded()

        assert Repo.aggregate(
                 from(j in Oban.Job, where: j.worker == ^inspect(ApplyImportCandidates)),
                 :count
               ) == 1

        assert Repo.get!(Oban.Job, job.id).state == unquote(state)
      end
    end

    test "only suppresses the same worker and library path", %{lp: lp, other_lp: other_lp} do
      queue(lp, "accept", "one.mkv")
      insert_job(RematchImportCandidates, %{"library_path_id" => lp.id}, "available")
      insert_job(ApplyImportCandidates, %{"library_path_id" => other_lp.id}, "available")

      assert {:ok, %{enqueued: 1}} = ImportCandidates.requeue_stranded()
    end
  end

  describe "executing drain rows" do
    test "a same-node row is cancelled and replaced by one fresh drain", %{lp: lp} do
      queue(lp, "accept", "one.mkv")

      orphan =
        insert_job(ApplyImportCandidates, %{"library_path_id" => lp.id}, "executing", [
          this_node()
        ])

      assert {:ok, %{retired: 1, enqueued: 1}} = ImportCandidates.requeue_stranded()

      reloaded = Repo.get!(Oban.Job, orphan.id)
      assert reloaded.state == "cancelled"
      assert reloaded.cancelled_at
      assert [fresh] = drain_jobs("available")
      refute fresh.id == orphan.id
    end

    test "a row from another node is left alone", %{lp: lp} do
      other =
        insert_job(ApplyImportCandidates, %{"library_path_id" => lp.id}, "executing", [
          "some-other-host",
          Ecto.UUID.generate()
        ])

      assert {:ok, %{retired: 0, enqueued: 0}} = ImportCandidates.requeue_stranded()
      assert Repo.get!(Oban.Job, other.id).state == "executing"
    end

    test "an executing ImportRun row is left alone" do
      run_job =
        insert_job(ImportRunJob, %{"import_run_id" => Ecto.UUID.generate()}, "executing", [
          this_node()
        ])

      assert {:ok, %{retired: 0}} = ImportCandidates.requeue_stranded()
      assert Repo.get!(Oban.Job, run_job.id).state == "executing"
    end
  end

  test "with nothing queued it does nothing and stays quiet" do
    log =
      capture_log([level: :warning], fn ->
        assert {:ok, %{retired: 0, enqueued: 0}} = ImportCandidates.requeue_stranded()
      end)

    assert log == ""
    assert Repo.all(Oban.Job) == []
  end

  describe "the supervision child" do
    test "does the work and then gets out of the way", %{lp: lp} do
      queue(lp, "rematch", "one.mkv")

      assert :ignore = Mydia.Jobs.ImportQueueReconciler.start_link([])

      assert [job] = drain_jobs("available")
      assert job.worker == inspect(RematchImportCandidates)
    end

    test "starts after the migrator and before Oban" do
      children = Mydia.Application.children(queues: [default: 1])

      migrator = Enum.find_index(children, &match?({Ecto.Migrator, _}, &1))
      reconciler = Enum.find_index(children, &(&1 == Mydia.Jobs.ImportQueueReconciler))
      oban = Enum.find_index(children, &match?({Oban, _}, &1))

      assert migrator, "expected an Ecto.Migrator child"
      assert reconciler, "expected a Mydia.Jobs.ImportQueueReconciler child"
      assert oban, "expected forcing an Oban config to produce an Oban child"

      assert migrator < reconciler
      assert reconciler < oban
    end
  end
end
