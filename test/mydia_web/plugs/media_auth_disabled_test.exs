defmodule MydiaWeb.Plugs.MediaAuthDisabledTest do
  use MydiaWeb.ConnCase, async: false

  alias Mydia.RemoteAccess
  alias Mydia.RemoteAccess.Pairing

  setup do
    reset_remote_access()
    on_exit(&reset_remote_access/0)

    user = create_test_user()

    {:ok, device} =
      RemoteAccess.create_device(%{
        device_name: "Test Phone",
        platform: "android",
        token: Base.encode64(:crypto.strong_rand_bytes(32), padding: false),
        user_id: user.id
      })

    media_token = Pairing.generate_media_token(device)

    %{user: user, device: device, media_token: media_token}
  end

  test "rejects a media token with 403 when remote access is disabled", %{
    conn: conn,
    media_token: media_token
  } do
    set_remote_access(false)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{media_token}")
      |> MydiaWeb.Plugs.MediaAuth.call([])

    assert conn.halted
    assert conn.status == 403
  end

  test "accepts the same media token when remote access is enabled", %{
    conn: conn,
    media_token: media_token,
    user: user
  } do
    set_remote_access(true)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{media_token}")
      |> MydiaWeb.Plugs.MediaAuth.call([])

    refute conn.halted
    assert conn.assigns[:media_user].id == user.id
  end

  test "leaves a locally authenticated request alone when disabled", %{conn: conn, user: user} do
    set_remote_access(false)

    conn =
      conn
      |> Plug.Conn.assign(:current_user, user)
      |> MydiaWeb.Plugs.MediaAuth.call([])

    refute conn.halted
  end
end
