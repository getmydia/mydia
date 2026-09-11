defmodule MydiaWeb.LibrarySchema.MonitoringTest do
  use MydiaWeb.ConnCase

  alias Mydia.LibraryApi.Principal
  alias Mydia.Media

  @admin %Principal{role: "admin", source: :env}

  defp run(document, variables) do
    Absinthe.run(document, MydiaWeb.LibrarySchema,
      variables: variables,
      context: %{principal: @admin}
    )
  end

  @set_item """
  mutation Set($id: ID!, $monitored: Boolean!) {
    setMediaItemMonitored(id: $id, monitored: $monitored) {
      mediaItem { id monitored }
      userErrors { field code message }
    }
  }
  """

  describe "setMediaItemMonitored" do
    test "turns monitoring off and returns the reloaded item" do
      item = insert(:media_item, monitored: true)

      assert {:ok, %{data: %{"setMediaItemMonitored" => payload}}} =
               run(@set_item, %{"id" => item.id, "monitored" => false})

      assert payload["userErrors"] == []
      assert payload["mediaItem"] == %{"id" => item.id, "monitored" => false}
      refute Media.get_media_item!(item.id).monitored
    end

    test "an id that names nothing is NOT_FOUND on id" do
      assert {:ok, %{data: %{"setMediaItemMonitored" => payload}}} =
               run(@set_item, %{"id" => Ecto.UUID.generate(), "monitored" => true})

      assert payload["mediaItem"] == nil
      assert [%{"code" => "NOT_FOUND", "field" => ["id"]}] = payload["userErrors"]
    end

    test "a malformed id is INVALID_INPUT on id" do
      assert {:ok, %{data: %{"setMediaItemMonitored" => payload}}} =
               run(@set_item, %{"id" => "not-a-uuid", "monitored" => true})

      assert [%{"code" => "INVALID_INPUT", "field" => ["id"]}] = payload["userErrors"]
    end
  end
end
