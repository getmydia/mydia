defmodule MydiaWeb.Plugs.AbsintheContextTest do
  use MydiaWeb.ConnCase, async: true

  alias Mydia.Streaming.DeviceProfile
  alias MydiaWeb.Plugs.AbsintheContext

  defp context(conn) do
    conn
    |> AbsintheContext.call(AbsintheContext.init([]))
    |> Map.fetch!(:private)
    |> get_in([:absinthe, :context])
  end

  test "omits device_profile when the assign is absent", %{conn: conn} do
    refute Map.has_key?(context(conn), :device_profile)
  end

  test "omits device_profile when the assign is nil", %{conn: conn} do
    conn = Plug.Conn.assign(conn, :device_profile, nil)

    refute Map.has_key?(context(conn), :device_profile)
  end

  test "carries the profile through when present", %{conn: conn} do
    profile = %DeviceProfile{containers: ["mkv"]}
    conn = Plug.Conn.assign(conn, :device_profile, profile)

    assert context(conn)[:device_profile] == profile
  end

  test "still carries remote_ip and source for an unauthenticated caller", %{conn: conn} do
    ctx = context(conn)

    assert ctx.source == :http
    assert is_binary(ctx.remote_ip)
  end
end
