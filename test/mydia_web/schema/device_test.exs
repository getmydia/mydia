defmodule MydiaWeb.Schema.DeviceTest do
  use MydiaWeb.ConnCase, async: false

  alias Mydia.RemoteAccess

  setup do
    user = Mydia.AccountsFixtures.user_fixture()

    {:ok, device} =
      RemoteAccess.create_device(%{
        device_name: "Living Room",
        platform: "linux",
        token: "tok_" <> Base.encode16(:crypto.strong_rand_bytes(16)),
        user_id: user.id
      })

    %{user: user, device: device}
  end

  describe "devices query" do
    test "returns the node id so the roster can drive a picker", %{
      user: user,
      device: device
    } do
      node_id = String.duplicate("a", 64)
      {:ok, _} = RemoteAccess.register_node_id(device, node_id)

      query = "query { devices { id deviceName platform nodeId } }"

      assert {:ok, %{data: %{"devices" => [returned]}}} =
               Absinthe.run(query, MydiaWeb.Schema, context: %{current_user: user})

      assert returned["nodeId"] == node_id
      assert returned["deviceName"] == "Living Room"
    end

    test "returns a null node id for a device that never reported one", %{user: user} do
      query = "query { devices { id nodeId } }"

      assert {:ok, %{data: %{"devices" => [returned]}}} =
               Absinthe.run(query, MydiaWeb.Schema, context: %{current_user: user})

      assert returned["nodeId"] == nil
    end

    test "reports a device seen a minute ago as online", %{user: user, device: device} do
      seen(device, 60)

      assert %{"online" => true} = only_device(user)
    end

    test "reports a device last seen sixteen minutes ago as offline", %{
      user: user,
      device: device
    } do
      seen(device, 960)

      assert %{"online" => false} = only_device(user)
    end

    test "reports a device that was never seen as offline", %{user: user, device: device} do
      device |> Ecto.Changeset.change(last_seen_at: nil) |> Mydia.Repo.update!()

      assert %{"online" => false} = only_device(user)
    end
  end

  describe "registerDeviceNode mutation" do
    test "records the node id of the calling device", %{user: user, device: device} do
      node_id = String.duplicate("b", 64)

      mutation = """
      mutation($nodeId: String!) {
        registerDeviceNode(nodeId: $nodeId) { id nodeId }
      }
      """

      assert {:ok, %{data: %{"registerDeviceNode" => returned}}} =
               Absinthe.run(mutation, MydiaWeb.Schema,
                 variables: %{"nodeId" => node_id},
                 context: %{current_user: user, device_id: device.id}
               )

      assert returned["nodeId"] == node_id
    end

    test "refuses a plain login, which is not a paired device", %{user: user} do
      mutation = """
      mutation($nodeId: String!) {
        registerDeviceNode(nodeId: $nodeId) { id }
      }
      """

      assert {:ok, %{errors: [_ | _]}} =
               Absinthe.run(mutation, MydiaWeb.Schema,
                 variables: %{"nodeId" => String.duplicate("c", 64)},
                 context: %{current_user: user}
               )
    end

    test "refuses to write to another user's device", %{device: device} do
      other = Mydia.AccountsFixtures.user_fixture()

      mutation = """
      mutation($nodeId: String!) {
        registerDeviceNode(nodeId: $nodeId) { id }
      }
      """

      assert {:ok, %{errors: [_ | _]}} =
               Absinthe.run(mutation, MydiaWeb.Schema,
                 variables: %{"nodeId" => String.duplicate("d", 64)},
                 context: %{current_user: other, device_id: device.id}
               )
    end

    test "refuses a revoked device holding an otherwise-valid token", %{
      user: user,
      device: device
    } do
      {:ok, revoked} = RemoteAccess.revoke_device(device)

      mutation = """
      mutation($nodeId: String!) {
        registerDeviceNode(nodeId: $nodeId) { id nodeId }
      }
      """

      assert {:ok, %{errors: [_ | _]}} =
               Absinthe.run(mutation, MydiaWeb.Schema,
                 variables: %{"nodeId" => String.duplicate("e", 64)},
                 context: %{current_user: user, device_id: revoked.id}
               )

      # The mutation must not have registered the node id either.
      refute RemoteAccess.get_device(revoked.id).node_id
    end
  end

  defp seen(device, seconds_ago) do
    at = DateTime.utc_now() |> DateTime.add(-seconds_ago, :second) |> DateTime.truncate(:second)

    device |> Ecto.Changeset.change(last_seen_at: at) |> Mydia.Repo.update!()
  end

  defp only_device(user) do
    assert {:ok, %{data: %{"devices" => [returned]}}} =
             Absinthe.run("query { devices { id online } }", MydiaWeb.Schema,
               context: %{current_user: user}
             )

    returned
  end
end
