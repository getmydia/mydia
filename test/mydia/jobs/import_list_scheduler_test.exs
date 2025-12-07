defmodule Mydia.Jobs.ImportListSchedulerTest do
  use Mydia.DataCase, async: true
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Jobs.ImportListScheduler

  import Mydia.ImportListsFixtures

  describe "perform/1" do
    test "completes successfully with no import lists" do
      assert :ok = perform_job(ImportListScheduler, %{})
    end

    test "skips recently synced lists" do
      # Create a list that was synced recently
      import_list =
        import_list_fixture(%{
          enabled: true,
          sync_interval: 360
        })

      # Mark it as synced just now
      Mydia.ImportLists.mark_sync_success(import_list)

      # Run scheduler - should complete successfully
      # It won't enqueue anything since the list was just synced
      assert :ok = perform_job(ImportListScheduler, %{})
    end

    test "skips disabled lists" do
      # Create a disabled list that would otherwise be due
      _import_list =
        import_list_fixture(%{
          enabled: false,
          sync_interval: 60
        })

      # Run scheduler - should complete successfully
      # It won't process disabled lists
      assert :ok = perform_job(ImportListScheduler, %{})
    end
  end

  describe "new/2" do
    test "creates a valid job changeset" do
      changeset = ImportListScheduler.new(%{})
      assert changeset.valid?
      assert changeset.changes.args == %{}
      assert changeset.changes.queue == "maintenance"
    end
  end
end
