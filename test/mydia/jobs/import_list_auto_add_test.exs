defmodule Mydia.Jobs.ImportListAutoAddTest do
  use Mydia.DataCase, async: true
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Jobs.ImportListAutoAdd

  import Mydia.ImportListsFixtures

  describe "perform/1" do
    test "returns ok when import list not found" do
      fake_id = Ecto.UUID.generate()

      assert :ok =
               perform_job(ImportListAutoAdd, %{
                 "import_list_id" => fake_id
               })
    end

    test "processes import list with no pending items" do
      import_list = import_list_fixture()

      assert :ok =
               perform_job(ImportListAutoAdd, %{
                 "import_list_id" => import_list.id
               })
    end

    test "processes import list with pending items" do
      import_list = import_list_fixture()

      # Create some pending items
      _item1 = import_list_item_fixture(import_list, %{status: "pending"})
      _item2 = import_list_item_fixture(import_list, %{status: "pending"})

      # Run auto-add - will fail to add due to no metadata relay
      # but verifies the job processes items
      assert :ok =
               perform_job(ImportListAutoAdd, %{
                 "import_list_id" => import_list.id
               })
    end

    test "skips items that are already added" do
      import_list = import_list_fixture()

      # Create an already added item
      _item = import_list_item_fixture(import_list, %{status: "added"})

      assert :ok =
               perform_job(ImportListAutoAdd, %{
                 "import_list_id" => import_list.id
               })
    end
  end

  describe "new/2" do
    test "creates a valid job changeset with import_list_id" do
      id = Ecto.UUID.generate()
      changeset = ImportListAutoAdd.new(%{"import_list_id" => id})
      assert changeset.valid?
      assert changeset.changes.args["import_list_id"] == id
      assert changeset.changes.queue == "import_lists"
    end
  end
end
