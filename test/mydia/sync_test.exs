defmodule Mydia.SyncTest do
  use Mydia.DataCase, async: true

  alias Mydia.Sync
  alias Mydia.Sync.Run

  @instance "11111111-1111-1111-1111-111111111111"

  test "a skip is recorded with a reason so a sync that never ran is visible" do
    assert {:ok, %Run{} = run} =
             Sync.record_skip(
               %{provider: "plex", provider_instance_id: @instance},
               :sync_disabled
             )

    assert run.status == :skipped
    assert run.skip_reason == "sync_disabled"
    assert run.finished_at
  end

  test "a run records counts on success" do
    {:ok, run} =
      Sync.start_run(%{
        provider: "plex",
        provider_instance_id: @instance,
        direction: :bidirectional
      })

    assert {:ok, done} = Sync.finish_run(run, :ok, %{imported: 3, exported: 2}, nil)

    assert done.status == :ok
    assert done.counts == %{"imported" => 3, "exported" => 2}
    assert done.finished_at

    # Atom-keyed input must read back identically whether the struct came from
    # the write or from a reload. The column round trips through Jason, so
    # without normalization these two disagree and consumers break depending on
    # which path handed them the row.
    assert Repo.get!(Run, done.id).counts == done.counts
  end

  test "a run records a classified error on failure" do
    {:ok, run} =
      Sync.start_run(%{provider: "plex", provider_instance_id: @instance, direction: :import})

    assert {:ok, done} = Sync.finish_run(run, :error, %{}, "Authentication failed: HTTP 401")

    assert done.status == :error
    assert done.error =~ "401"
  end

  test "last_run returns the most recent run for an instance" do
    {:ok, _old} =
      Sync.record_skip(%{provider: "plex", provider_instance_id: @instance}, :sync_disabled)

    {:ok, newer} =
      Sync.record_skip(%{provider: "plex", provider_instance_id: @instance}, :no_user_mapping)

    assert Sync.last_run("plex", @instance).id == newer.id
  end

  test "prune deletes runs older than the retention window" do
    {:ok, run} =
      Sync.record_skip(%{provider: "plex", provider_instance_id: @instance}, :sync_disabled)

    old = DateTime.utc_now() |> DateTime.add(-40, :day) |> DateTime.truncate(:second)
    Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [inserted_at: old])

    assert {1, nil} = Sync.prune(30)
    assert Sync.last_run("plex", @instance) == nil
  end
end
