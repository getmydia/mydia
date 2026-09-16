defmodule MydiaWeb.Plugs.AbsintheContextTest do
  use MydiaWeb.ConnCase, async: true

  alias Mydia.Auth.Guardian
  alias Mydia.RemoteAccess
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

  test "carries both device_profile and current_user for an authenticated caller", %{
    conn: conn
  } do
    # This is the Flutter player's actual request shape: always authenticated,
    # always sending the profile header. A refactor that rebuilds the context
    # inside the authenticated branch instead of threading `base` through it
    # would silently drop device_profile here while every other test stays
    # green, so this combination needs its own coverage.
    user = create_test_user()
    profile = %DeviceProfile{containers: ["mkv"]}

    conn =
      conn
      |> Guardian.Plug.put_current_resource(user)
      |> Plug.Conn.assign(:device_profile, profile)

    ctx = context(conn)

    assert ctx[:current_user].id == user.id
    assert ctx[:device_profile] == profile
  end

  describe "media_token_auth propagation (T-108)" do
    test "omits media_token_auth when the assign is absent", %{conn: conn} do
      refute Map.has_key?(context(conn), :media_token_auth)
    end

    # MydiaWeb.Schema.Resolvers.ApiKeyResolver.create_api_key/3 refuses to
    # mint an API key when this is set, so a request MediaAuth authenticated
    # must carry it into the Absinthe context even though no route currently
    # mounts MediaAuth ahead of :graphql_context (see the :api_auth pipeline
    # comment in the router). Without this propagation, that resolver-level
    # refusal could never see the signal MediaAuth put on the connection.
    test "carries media_token_auth through when MediaAuth set the assign", %{conn: conn} do
      user = create_test_user()

      conn =
        conn
        |> Guardian.Plug.put_current_resource(user)
        |> Plug.Conn.assign(:media_token_auth, true)

      ctx = context(conn)

      assert ctx[:current_user].id == user.id
      assert ctx[:media_token_auth] == true
    end
  end

  describe "device liveness over HTTP" do
    # A player on direct HTTP never reaches the p2p handlers, which were the
    # only place liveness was recorded, so it read as offline while playing.
    defp paired_device(user) do
      {:ok, device} =
        RemoteAccess.create_device(%{
          device_name: "Hall Screen",
          platform: "android",
          token: "tok_" <> Base.encode16(:crypto.strong_rand_bytes(16)),
          user_id: user.id
        })

      device
    end

    test "records liveness for a paired device's access token", %{conn: conn} do
      user = create_test_user()
      device = paired_device(user)
      assert is_nil(device.last_seen_at)

      conn
      |> Guardian.Plug.put_current_resource(user)
      |> Guardian.Plug.put_current_claims(%{"sub" => user.id, "device_id" => device.id})
      |> context()

      assert Mydia.Repo.reload!(device).last_seen_at != nil
    end

    test "leaves devices alone for a plain login", %{conn: conn} do
      user = create_test_user()
      device = paired_device(user)

      conn
      |> Guardian.Plug.put_current_resource(user)
      |> Guardian.Plug.put_current_claims(%{"sub" => user.id})
      |> context()

      assert is_nil(Mydia.Repo.reload!(device).last_seen_at)
    end
  end
end
