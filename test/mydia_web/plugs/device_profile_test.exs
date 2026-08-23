defmodule MydiaWeb.Plugs.DeviceProfileTest do
  use MydiaWeb.ConnCase, async: true

  alias Mydia.Streaming.DeviceProfile
  alias MydiaWeb.Plugs.DeviceProfile, as: Plug

  defp encode(map), do: Base.url_encode64(Jason.encode!(map), padding: false)

  defp call(conn), do: Plug.call(conn, Plug.init([]))

  test "assigns nil when the header is absent", %{conn: conn} do
    assert call(conn).assigns[:device_profile] == nil
  end

  test "parses a valid header into a profile", %{conn: conn} do
    header = encode(%{"containers" => ["mkv"], "videoCodecs" => ["hevc"]})

    conn = conn |> put_req_header("x-mydia-device-profile", header) |> call()

    assert %DeviceProfile{containers: ["mkv"], video_codecs: ["hevc"]} =
             conn.assigns[:device_profile]
  end

  test "treats a non-base64 header as absent", %{conn: conn} do
    conn = conn |> put_req_header("x-mydia-device-profile", "not base64!!") |> call()

    assert conn.assigns[:device_profile] == nil
  end

  test "treats base64 that is not JSON as absent", %{conn: conn} do
    header = Base.url_encode64("this is not json", padding: false)

    conn = conn |> put_req_header("x-mydia-device-profile", header) |> call()

    assert conn.assigns[:device_profile] == nil
  end

  test "treats JSON that is not an object as absent", %{conn: conn} do
    header = encode(["mp4"])

    conn = conn |> put_req_header("x-mydia-device-profile", header) |> call()

    assert conn.assigns[:device_profile] == nil
  end

  test "treats an over-cap payload as absent rather than erroring", %{conn: conn} do
    header = encode(%{"containers" => Enum.map(1..65, &"c#{&1}")})

    conn = conn |> put_req_header("x-mydia-device-profile", header) |> call()

    assert conn.assigns[:device_profile] == nil
    assert conn.status == nil
  end

  test "treats a payload over 4 KB as absent without decoding it", %{conn: conn} do
    header = Base.url_encode64(String.duplicate("a", 5000), padding: false)

    conn = conn |> put_req_header("x-mydia-device-profile", header) |> call()

    assert conn.assigns[:device_profile] == nil
  end

  test "never halts the connection, whatever the header says", %{conn: conn} do
    conn = conn |> put_req_header("x-mydia-device-profile", "garbage") |> call()

    refute conn.halted
  end
end
