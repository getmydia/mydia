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

  describe "record_run/1" do
    test "stores a finished run in one insert, including :partial" do
      started = ~U[2026-09-29 10:00:00Z]
      finished = ~U[2026-09-29 10:00:42Z]

      assert {:ok, run} =
               Mydia.Sync.record_run(%{
                 provider: "plugin:plex",
                 provider_instance_id: "inst-1",
                 direction: :bidirectional,
                 status: :partial,
                 started_at: started,
                 finished_at: finished,
                 counts: %{pulled: 3, pushed: 1, skipped: 0, errors: 1},
                 error: "one profile token expired"
               })

      assert run.status == :partial
      assert run.counts == %{"pulled" => 3, "pushed" => 1, "skipped" => 0, "errors" => 1}
      assert Mydia.Sync.last_run("plugin:plex", "inst-1").id == run.id
    end
  end

  describe "last_successful_run_started_at/3" do
    setup do
      {:ok,
       user: Mydia.AccountsFixtures.user_fixture(), other: Mydia.AccountsFixtures.user_fixture()}
    end

    defp finished(user, status, started_at) do
      {:ok, _} =
        Sync.record_run(%{
          provider: "jellyfin",
          provider_instance_id: @instance,
          user_id: user.id,
          status: status,
          started_at: started_at,
          finished_at: started_at
        })
    end

    test "is the newest finished :ok run for that user", %{user: user, other: other} do
      older = ~U[2026-10-01 10:00:00Z]
      newer = ~U[2026-10-02 10:00:00Z]
      finished(user, :ok, older)
      finished(user, :ok, newer)
      finished(user, :error, ~U[2026-10-03 10:00:00Z])
      finished(other, :ok, ~U[2026-10-04 10:00:00Z])

      assert Sync.last_successful_run_started_at("jellyfin", @instance, user.id) == newer
    end

    test "ignores a run that has not finished", %{user: user} do
      {:ok, _} =
        Sync.start_run(%{provider: "jellyfin", provider_instance_id: @instance, user_id: user.id})

      assert Sync.last_successful_run_started_at("jellyfin", @instance, user.id) == nil
    end
  end
end
