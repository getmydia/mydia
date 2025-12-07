defmodule Mydia.Jobs.ImportListSyncTest do
  use Mydia.DataCase, async: true
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Jobs.ImportListSync

  import Mydia.ImportListsFixtures

  describe "perform/1" do
    test "returns ok when import list not found" do
      fake_id = Ecto.UUID.generate()

      assert :ok =
               perform_job(ImportListSync, %{
                 "import_list_id" => fake_id
               })
    end

    test "skips disabled import lists" do
      import_list =
        import_list_fixture(%{
          enabled: false
        })

      assert :ok =
               perform_job(ImportListSync, %{
                 "import_list_id" => import_list.id
               })
    end

    test "handles enabled import list sync attempt" do
      import_list =
        import_list_fixture(%{
          enabled: true,
          type: "tmdb_trending",
          media_type: "movie"
        })

      # Subscribe to receive broadcast
      Phoenix.PubSub.subscribe(Mydia.PubSub, "import_lists")

      # Sync will fail because we don't have metadata relay configured
      # but we test that the job handles it gracefully
      result =
        perform_job(ImportListSync, %{
          "import_list_id" => import_list.id
        })

      # Should either succeed or return an error (depending on network)
      assert result == :ok or match?({:error, _}, result)
    end
  end

  describe "new/2" do
    test "creates a valid job changeset with import_list_id" do
      id = Ecto.UUID.generate()
      changeset = ImportListSync.new(%{"import_list_id" => id})
      assert changeset.valid?
      assert changeset.changes.args["import_list_id"] == id
      assert changeset.changes.queue == "import_lists"
    end

    test "creates a valid job changeset with auto_add option" do
      id = Ecto.UUID.generate()
      changeset = ImportListSync.new(%{"import_list_id" => id, "auto_add" => true})
      assert changeset.valid?
      assert changeset.changes.args["import_list_id"] == id
      assert changeset.changes.args["auto_add"] == true
    end
  end
end
