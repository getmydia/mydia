defmodule Mydia.WatchSync.Providers.PlexPositionTest do
  use ExUnit.Case, async: true

  alias Mydia.MediaServer.Client.Plex
  alias Mydia.Settings.MediaServerConfig

  # Bypass cannot register or match paths like "/:/progress" (Plug treats ":" as
  # a route param marker). A plain Bandit plug receives the literal path.
  defmodule FakePlex do
    @behaviour Plug

    def init(test_pid), do: test_pid

    def call(conn, test_pid) do
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.request_path do
        "/library/sections" ->
          # Endpoint.resolve probes this before any real call.
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, ~s({"MediaContainer":{"Directory":[]}}))

        "/:/progress" ->
          send(test_pid, {:progress, conn.query_params})
          Plug.Conn.resp(conn, 200, "")

        other ->
          send(test_pid, {:unexpected, other})
          Plug.Conn.resp(conn, 404, "")
      end
    end
  end

  setup do
    {:ok, pid} =
      Bandit.start_link(
        plug: {FakePlex, self()},
        port: 0,
        startup_log: false
      )

    on_exit(fn ->
      Process.exit(pid, :normal)
    end)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)

    config = %MediaServerConfig{
      name: "T",
      type: :plex,
      url: "http://127.0.0.1:#{port}",
      token: "tok"
    }

    {:ok, config: config}
  end

  test "position is pushed in milliseconds", %{config: config} do
    assert :ok = Plex.update_progress(config, "rk1", 125, "stopped")

    assert_receive {:progress, params}

    # Plex takes milliseconds. Sending seconds would put every resume point
    # 1000x too early, which reads as "resume never worked".
    assert params["time"] == "125000"
    assert params["key"] == "rk1"
    assert params["identifier"] == "com.plexapp.plugins.library"
  end
end
