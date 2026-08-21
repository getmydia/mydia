defmodule Mydia.RemoteAccess.NodeIdTest do
  @moduledoc """
  A controller looks up where to dial a paired device by its iroh node ID, so
  the server has to remember it. These cover `register_node_id/2`, which
  records that ID on a device independently of the pairing flow.
  """
  use Mydia.DataCase, async: true

  alias Mydia.RemoteAccess

  describe "register_node_id/2" do
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

    test "records a node id on a device", %{device: device} do
      node_id = String.duplicate("a", 64)

      assert {:ok, updated} = RemoteAccess.register_node_id(device, node_id)
      assert updated.node_id == node_id
    end

    test "replaces a node id when a device is re-keyed", %{device: device} do
      {:ok, _} = RemoteAccess.register_node_id(device, String.duplicate("a", 64))
      {:ok, updated} = RemoteAccess.register_node_id(device, String.duplicate("b", 64))

      assert updated.node_id == String.duplicate("b", 64)
    end

    test "rejects an implausible node id", %{device: device} do
      assert {:error, changeset} = RemoteAccess.register_node_id(device, "nope")
      assert %{node_id: [_ | _]} = Ecto.Changeset.traverse_errors(changeset, & &1)
    end

    test "two devices may hold the same node id", %{user: user, device: device} do
      # A re-paired device reuses its persisted keypair, so a stale revoked row
      # can legitimately carry the same node id. A unique index would turn that
      # into a pairing failure.
      node_id = String.duplicate("c", 64)
      {:ok, _} = RemoteAccess.register_node_id(device, node_id)

      {:ok, second} =
        RemoteAccess.create_device(%{
          device_name: "Living Room (re-paired)",
          platform: "linux",
          token: "tok_" <> Base.encode16(:crypto.strong_rand_bytes(16)),
          user_id: user.id
        })

      assert {:ok, _} = RemoteAccess.register_node_id(second, node_id)
    end
  end
end
