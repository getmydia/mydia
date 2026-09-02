defmodule Mydia.RemoteAccess.LoginDeviceTest do
  @moduledoc """
  Covers `find_or_create_login_device/1`, the password-login counterpart to
  the pairing flow. Two concurrent first-time logins for the same
  `client_device_id` can both pass the initial lookup before either insert
  lands; the loser used to hit the `[:user_id, :client_device_id]` unique
  constraint and surface as "Failed to register this device" for what was a
  legitimate login.

  `async: false` is load-bearing: `Mydia.DataCase` only shares the sandboxed
  connection across processes when the test is not async, and the concurrent
  case below needs the spawned tasks to see each other's writes.
  """
  use Mydia.DataCase, async: false

  alias Mydia.RemoteAccess
  alias Mydia.RemoteAccess.RemoteDevice

  describe "find_or_create_login_device/1" do
    setup do
      %{user: Mydia.AccountsFixtures.user_fixture()}
    end

    test "creates a device on first login", %{user: user} do
      assert {:ok, device} =
               RemoteAccess.find_or_create_login_device(%{
                 user_id: user.id,
                 client_device_id: "client-first",
                 device_name: "Living Room",
                 platform: "linux"
               })

      assert device.client_device_id == "client-first"
      assert device.user_id == user.id
    end

    test "returns the same row on a returning login", %{user: user} do
      attrs = %{
        user_id: user.id,
        client_device_id: "client-returning",
        device_name: "Living Room",
        platform: "linux"
      }

      assert {:ok, first} = RemoteAccess.find_or_create_login_device(attrs)
      assert {:ok, second} = RemoteAccess.find_or_create_login_device(attrs)

      assert first.id == second.id
    end

    test "still fails for a genuine validation error", %{user: user} do
      assert {:error, changeset} =
               RemoteAccess.find_or_create_login_device(%{
                 user_id: user.id,
                 client_device_id: "client-invalid",
                 # Missing device_name and platform: a real validation
                 # failure, which the unique-constraint recovery path must
                 # not paper over.
                 device_name: nil,
                 platform: nil
               })

      refute changeset.valid?
    end

    test "the loser of a concurrent first login gets the winner's row instead of an error",
         %{user: user} do
      client_device_id = "client-concurrent-#{System.unique_integer([:positive])}"
      attempts = 8

      results =
        1..attempts
        |> Task.async_stream(
          fn _ ->
            RemoteAccess.find_or_create_login_device(%{
              user_id: user.id,
              client_device_id: client_device_id,
              device_name: "Concurrent Client",
              platform: "linux"
            })
          end,
          max_concurrency: attempts,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, %RemoteDevice{}}, &1)),
             "every concurrent login must resolve to a device, not the unique-constraint error"

      device_ids = results |> Enum.map(fn {:ok, device} -> device.id end) |> Enum.uniq()

      assert device_ids == [hd(device_ids)],
             "every concurrent login for the same client_device_id must resolve to one row"

      assert Repo.aggregate(
               from(d in RemoteDevice,
                 where: d.user_id == ^user.id and d.client_device_id == ^client_device_id
               ),
               :count
             ) == 1
    end
  end
end
