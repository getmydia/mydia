defmodule Mydia.RemoteAccess.DeviceLivenessTest do
  @moduledoc """
  The remote access admin page decides a device is "online" purely from
  `last_seen_at`. Every writer of that column belonged to the pre-iroh relay
  tunnel, so a player actively talking over p2p still rendered as "Never
  connected". These cover the seam that records liveness from a verified p2p
  access token.
  """
  use Mydia.DataCase, async: false

  alias Mydia.Accounts
  alias Mydia.Auth.Guardian
  alias Mydia.RemoteAccess
  alias Mydia.RemoteAccess.Pairing
  alias Mydia.RemoteAccess.RemoteDevice
  alias Mydia.Repo

  setup do
    user = create_user()
    %{user: user, device: create_device(user)}
  end

  describe "touch_device_if_stale/1" do
    test "records liveness for a device that has never been seen", %{device: device} do
      assert is_nil(device.last_seen_at)

      assert :recorded = RemoteAccess.touch_device_if_stale(device.id)

      assert Repo.reload!(device).last_seen_at != nil
    end

    test "refreshes a device last seen longer ago than the throttle window", %{device: device} do
      stale = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
      device = device |> Ecto.Changeset.change(last_seen_at: stale) |> Repo.update!()

      assert :recorded = RemoteAccess.touch_device_if_stale(device.id)

      assert DateTime.compare(Repo.reload!(device).last_seen_at, stale) == :gt
    end

    test "leaves a device touched moments ago alone", %{device: device} do
      fresh = DateTime.utc_now() |> DateTime.truncate(:second)
      device = device |> Ecto.Changeset.change(last_seen_at: fresh) |> Repo.update!()

      assert :skipped = RemoteAccess.touch_device_if_stale(device.id)

      assert DateTime.compare(Repo.reload!(device).last_seen_at, fresh) == :eq
    end

    test "accepts a loaded device as well as an id", %{device: device} do
      assert :recorded = RemoteAccess.touch_device_if_stale(device)

      assert Repo.reload!(device).last_seen_at != nil
    end

    test "skips an unknown device id rather than raising" do
      assert :skipped = RemoteAccess.touch_device_if_stale(Ecto.UUID.generate())
    end

    test "concurrent requests for one device write exactly once", %{device: device} do
      # A paired player holds a GraphQL and an HLS connection at once, handled in
      # separate processes. The throttle window lives inside the UPDATE, so only
      # one of them can match a row however the two interleave.
      results =
        1..4
        |> Enum.map(fn _ ->
          Task.async(fn -> RemoteAccess.touch_device_if_stale(device.id) end)
        end)
        |> Task.await_many(5_000)

      assert Enum.count(results, &(&1 == :recorded)) == 1
      assert Enum.count(results, &(&1 == :skipped)) == 3
    end
  end

  describe "touch_device_from_claims/1" do
    test "records liveness for the device named in the claims", %{device: device} do
      claims = %{"device_id" => device.id}

      assert :ok = RemoteAccess.touch_device_from_claims(claims)

      assert Repo.reload!(device).last_seen_at != nil
    end

    test "ignores claims that carry no device id", %{device: device} do
      assert :ok = RemoteAccess.touch_device_from_claims(%{"sub" => device.user_id})

      assert is_nil(Repo.reload!(device).last_seen_at)
    end
  end

  describe "access token claims" do
    test "a device access token carries its device id through verification", %{
      user: user,
      device: device
    } do
      {:ok, token, _claims} = Pairing.generate_access_token_with_claims(device)

      assert {:ok, verified_user, claims} = Guardian.verify_token_with_claims(token)

      assert verified_user.id == user.id
      assert claims["device_id"] == device.id
    end
  end

  defp create_user do
    {:ok, user} =
      Accounts.create_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        username: "user#{System.unique_integer([:positive])}",
        password: "password123",
        role: "user"
      })

    user
  end

  defp create_device(user) do
    %RemoteDevice{}
    |> RemoteDevice.changeset(%{
      device_name: "Test Device #{System.unique_integer([:positive])}",
      platform: "ios",
      device_static_public_key: :crypto.strong_rand_bytes(32),
      token: "device-token-#{System.unique_integer([:positive])}",
      user_id: user.id
    })
    |> Repo.insert!()
  end
end
