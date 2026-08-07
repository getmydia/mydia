defmodule Mydia.Accounts.ChangelogPreferenceTest do
  use Mydia.DataCase, async: true

  alias Mydia.Accounts

  defp user_fixture do
    unique_id = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        email: "changelog_#{unique_id}@example.com",
        username: "changelog_#{unique_id}",
        password_hash: "$2b$12$test",
        role: "user"
      })

    user
  end

  describe "last_seen_changelog_version/1" do
    test "is nil for a user who has never seen the changelog" do
      assert Accounts.last_seen_changelog_version(user_fixture()) == nil
    end

    test "creates the preferences row lazily rather than raising" do
      user = user_fixture()
      assert Accounts.last_seen_changelog_version(user) == nil
      assert Accounts.get_user_preference!(user)
    end

    test "returns what was stored" do
      user = user_fixture()
      {:ok, _} = Accounts.mark_changelog_seen(user, "0.12.0")
      assert Accounts.last_seen_changelog_version(user) == "0.12.0"
    end
  end

  describe "mark_changelog_seen/2" do
    test "moves the stored version forward" do
      user = user_fixture()
      {:ok, _} = Accounts.mark_changelog_seen(user, "0.12.0")
      {:ok, _} = Accounts.mark_changelog_seen(user, "0.13.0")
      assert Accounts.last_seen_changelog_version(user) == "0.13.0"
    end

    test "refuses to move the stored version backward" do
      user = user_fixture()
      {:ok, _} = Accounts.mark_changelog_seen(user, "0.13.0")
      {:ok, _} = Accounts.mark_changelog_seen(user, "0.12.0")
      assert Accounts.last_seen_changelog_version(user) == "0.13.0"
    end

    test "is a no-op when the same version is written twice" do
      user = user_fixture()
      {:ok, _} = Accounts.mark_changelog_seen(user, "0.13.0")
      {:ok, _} = Accounts.mark_changelog_seen(user, "0.13.0")
      assert Accounts.last_seen_changelog_version(user) == "0.13.0"
    end

    test "overwrites an unparseable stored value" do
      user = user_fixture()
      pref = Accounts.get_user_preference!(user)
      {:ok, _} = Accounts.update_preference(pref, %{"last_seen_changelog_version" => "garbage"})

      {:ok, _} = Accounts.mark_changelog_seen(user, "0.13.0")
      assert Accounts.last_seen_changelog_version(user) == "0.13.0"
    end

    test "preserves unrelated preferences" do
      user = user_fixture()
      pref = Accounts.get_user_preference!(user)
      {:ok, _} = Accounts.update_preference(pref, %{"theme" => "dark"})

      {:ok, _} = Accounts.mark_changelog_seen(user, "0.13.0")

      preferences = Accounts.get_user_preference!(user).preferences
      assert preferences["theme"] == "dark"
      assert preferences["last_seen_changelog_version"] == "0.13.0"
    end

    test "an unparseable new version leaves a valid stored value untouched" do
      user = user_fixture()
      {:ok, _} = Accounts.mark_changelog_seen(user, "0.13.0")
      {:ok, _} = Accounts.mark_changelog_seen(user, "not-a-version")
      assert Accounts.last_seen_changelog_version(user) == "0.13.0"
    end

    test "an unparseable new version stores nothing for a user who has none" do
      user = user_fixture()
      {:ok, _} = Accounts.mark_changelog_seen(user, "not-a-version")
      assert Accounts.last_seen_changelog_version(user) == nil
    end

    test "a prerelease is not newer than its stable release" do
      user = user_fixture()
      {:ok, _} = Accounts.mark_changelog_seen(user, "0.13.0")
      {:ok, _} = Accounts.mark_changelog_seen(user, "0.13.0-beta.1")
      assert Accounts.last_seen_changelog_version(user) == "0.13.0"
    end
  end

  describe "get_user_preference!/1 racing a concurrent first-mount insert" do
    test "both racers return an updatable row that points at the same id" do
      user = user_fixture()
      test_pid = self()

      # Force the exact race two mounts hit on a user's first page load: both
      # processes must see no row from `Repo.get_by/2` before either attempts
      # the insert, so the second insert always lands on a real unique_index
      # conflict instead of maybe finding the first process's row already
      # committed. A telemetry handler on the repo's query event pauses each
      # process right after its own `SELECT ... FROM "user_preferences"` and
      # releases both together, once both have arrived.
      {:ok, barrier} = Agent.start_link(fn -> [] end)
      handler_id = {__MODULE__, :first_mount_race, test_pid}

      :telemetry.attach(
        handler_id,
        [:mydia, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          query = String.trim_leading(metadata.query)

          # get_user_preference!/1 issues a second, identical-shaped SELECT to
          # re-read after the insert; only the first SELECT per process is the
          # rendezvous point, so a process-local flag keeps that re-read from
          # blocking on the barrier a second time.
          # The handler is VM-global and runs in whichever process issued the
          # query, so it must ignore anything that is not one of this test's two
          # racers. Without the participant flag, a concurrently-running async
          # test that touches user_preferences would consume a barrier slot and
          # silently stop these two from rendezvousing at all.
          #
          # The `false` default on Process.get/2 is load-bearing, not cosmetic:
          # `and` requires a strict boolean, and Process.get/1 returns `nil` for
          # every non-participant process. Under CI's concurrency, some other
          # async test's query is virtually guaranteed to hit this handler while
          # it is attached; `nil and ...` raises inside the handler, and
          # :telemetry detaches a crashing handler permanently. If that happens
          # after one racer has already registered on the barrier but before
          # the other racer's SELECT fires, the detached handler never runs for
          # the second racer, the first racer's `receive` below never gets its
          # :first_mount_race_go, and the test hangs until Task.await_many times
          # out. This is not hypothetical: it reproduced locally (handler crash
          # logged, detached mid-test) before this default was added.
          if Process.get(:first_mount_race_participant, false) and
               metadata.source == "user_preferences" and String.starts_with?(query, "SELECT") and
               is_nil(Process.get(:first_mount_race_synced)) do
            Process.put(:first_mount_race_synced, true)
            me = self()

            case Agent.get_and_update(barrier, fn arrived -> {[me | arrived], [me | arrived]} end) do
              [_, _] = both -> Enum.each(both -- [me], &send(&1, :first_mount_race_go))
              [_one] -> receive(do: (:first_mount_race_go -> :ok))
            end
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, test_pid, self())
            Process.put(:first_mount_race_participant, true)
            Accounts.get_user_preference!(user)
          end)
        end

      # 2s was tight under CI's PostgreSQL job even with the handler crash
      # above fixed: this test's two racer processes share the single DB
      # connection the test already checked out of the sandbox pool, so their
      # queries serialize on it, and under CI's concurrent-test load the
      # shared Postgres server and a schedulers_online()-sized batch of async
      # test modules can legitimately push each query's round trip well past
      # a couple hundred ms. This is slack for contention, not a change to
      # the rendezvous logic above.
      [pref_a, pref_b] = Task.await_many(tasks, 5_000)

      # Whichever process lost the race, get_user_preference!/1 must hand
      # both callers the row that is actually in the database, not a
      # struct describing the insert it thought it made. UserPreference's
      # :binary_id primary key is generated client-side, so a losing
      # Repo.insert/2 still returns {:ok, struct} with a populated id, one
      # that names no row; the old code trusted that struct directly instead
      # of re-reading, and update_preference/2 on it would raise
      # Ecto.StaleEntryError.
      assert pref_a.id == pref_b.id
      assert {:ok, _} = Accounts.update_preference(pref_a, %{"theme" => "dark"})
      assert {:ok, _} = Accounts.update_preference(pref_b, %{"theme" => "light"})
    end
  end
end
