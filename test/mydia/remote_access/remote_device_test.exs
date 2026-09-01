defmodule Mydia.RemoteAccess.RemoteDeviceTest do
  use Mydia.DataCase, async: true

  alias Mydia.RemoteAccess.RemoteDevice

  describe "login_changeset/2" do
    test "records the client-supplied device identifier without a token" do
      changeset =
        RemoteDevice.login_changeset(%RemoteDevice{}, %{
          client_device_id: "client-abc",
          device_name: "Test Laptop",
          platform: "macos",
          user_id: Ecto.UUID.generate()
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :client_device_id) == "client-abc"
    end

    test "requires the client device identifier" do
      changeset =
        RemoteDevice.login_changeset(%RemoteDevice{}, %{
          device_name: "Test Laptop",
          platform: "macos",
          user_id: Ecto.UUID.generate()
        })

      refute changeset.valid?
      assert %{client_device_id: _} = errors_on(changeset)
    end
  end
end
