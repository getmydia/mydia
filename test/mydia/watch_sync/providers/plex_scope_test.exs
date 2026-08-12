defmodule Mydia.WatchSync.Providers.PlexScopeTest do
  use ExUnit.Case, async: true

  alias Mydia.Settings.MediaServerConfig
  alias Mydia.WatchSync.Providers.Plex

  # Any request reaching this plug means the provider made an HTTP call. The
  # tests below assert on whether that message ever arrives, not just on the
  # return value, so a regression that silently falls back to the admin token
  # is caught even if it happens to still return an error tuple.
  defmodule FakePlex do
    @behaviour Plug

    def init(test_pid), do: test_pid

    def call(conn, test_pid) do
      send(test_pid, {:request, conn.request_path})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"MediaContainer":{"Directory":[]}}))
    end
  end

  setup do
    {:ok, pid} =
      Bandit.start_link(
        plug: {FakePlex, self()},
        port: 0,
        startup_log: false
      )

    on_exit(fn -> Process.exit(pid, :normal) end)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)

    config = %MediaServerConfig{
      name: "T",
      type: :plex,
      url: "http://127.0.0.1:#{port}",
      token: "admin-token"
    }

    {:ok, config: config}
  end

  # This is Critical 1's direct coverage: a scope with no per-user Plex token
  # must never fall back to config.token (the server's own admin credential).
  # Falling back would sync this user against the admin's Plex watch state,
  # which is exactly the merge bug per-user links exist to prevent.
  describe "with no usable per-user token in scope" do
    test "list_changes/3 refuses without contacting Plex", %{config: config} do
      scope = %{user_id: "u1", remote_user_id: "2", access_token: nil}

      assert {:error, :missing_user_token} = Plex.list_changes(config, scope, nil)
      refute_receive {:request, _}, 100
    end

    test "apply_change/4 refuses without contacting Plex", %{config: config} do
      scope = %{user_id: "u1", remote_user_id: "2", access_token: nil}
      change = %{watched: true, position_seconds: nil}

      assert {:error, :missing_user_token} = Plex.apply_change(config, scope, "rk1", change)
      refute_receive {:request, _}, 100
    end

    test "a blank string token is treated the same as nil", %{config: config} do
      scope = %{user_id: "u1", remote_user_id: nil, access_token: ""}

      assert {:error, :missing_user_token} = Plex.list_changes(config, scope, nil)
      refute_receive {:request, _}, 100
    end
  end

  describe "with a usable per-user token in scope" do
    test "list_changes/3 swaps the scope token in and proceeds", %{config: config} do
      scope = %{user_id: "u1", remote_user_id: "2", access_token: "user-token"}

      assert {:ok, []} = Plex.list_changes(config, scope, nil)
      assert_receive {:request, "/library/sections"}
    end
  end
end
