defmodule Mydia.RemoteAccess.RemoteDeviceTest do
  use Mydia.DataCase, async: true

  alias Mydia.RemoteAccess.RemoteDevice

  describe "login_changeset/2" do
    test "records the client-supplied device identifier when a token is provided" do
      changeset =
        RemoteDevice.login_changeset(%RemoteDevice{}, %{
          client_device_id: "client-abc",
          device_name: "Test Laptop",
          platform: "macos",
          token: "unused-generated-token",
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
          token: "unused-generated-token",
          user_id: Ecto.UUID.generate()
        })

      refute changeset.valid?
      assert %{client_device_id: _} = errors_on(changeset)
    end

    test "requires a token, because token_hash is NOT NULL at the database level" do
      changeset =
        RemoteDevice.login_changeset(%RemoteDevice{}, %{
          client_device_id: "client-abc",
          device_name: "Test Laptop",
          platform: "macos",
          user_id: Ecto.UUID.generate()
        })

      refute changeset.valid?
      assert %{token: _} = errors_on(changeset)
    end

    test "inserts successfully and hashes the token, matching the DB constraints" do
      user = Mydia.AccountsFixtures.user_fixture()

      assert {:ok, device} =
               %RemoteDevice{}
               |> RemoteDevice.login_changeset(%{
                 client_device_id: "client-abc",
                 device_name: "Test Laptop",
                 platform: "macos",
                 token: "unused-generated-token",
                 user_id: user.id
               })
               |> Mydia.Repo.insert()

      assert device.client_device_id == "client-abc"
      assert is_binary(device.token_hash)
      # The plaintext is never persisted; only its hash is.
      refute device.token_hash == "unused-generated-token"
      assert is_nil(device.token)
    end
  end
end
