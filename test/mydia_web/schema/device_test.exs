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
end
