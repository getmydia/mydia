defmodule MetadataRelayWeb.LogsRawControllerTest do
  use ExUnit.Case, async: false

  import MetadataRelay.PlayerLogsHelpers
  import Phoenix.ConnTest
  import Plug.Conn

  alias MetadataRelay.{PlayerLogs, Repo}

  @endpoint MetadataRelayWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    use_tmp_logs_dir()
    :ok
  end

  defp raw(params) do
    build_conn()
    |> put_req_header("authorization", "Basic " <> Base.encode64("admin:admin"))
    |> get("/logs/raw?" <> URI.encode_query(params))
  end

  defp now_ms, do: System.system_time(:millisecond)

  defp lines(conn), do: String.split(conn.resp_body, "\n", trim: true)

  test "requires the dashboard credentials" do
    assert build_conn() |> get("/logs/raw?device=anything") |> Map.get(:status) == 401
  end

  test "prints a device's recent lines, oldest first, after a header" do
    t = now_ms()

    {:ok, :stream} =
      PlayerLogs.ingest(
        batch(
          records: [
            record_map(%{"t" => t - 2_000, "msg" => "first"}),
            record_map(%{"t" => t - 1_000, "l" => "warn", "tag" => "P2P", "msg" => "second"})
          ]
        )
      )

    conn = raw(%{"device" => device_id()})

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert [header, first, second] = lines(conn)
    assert header =~ "# device Work MacBook (#{device_id()})"

    assert first =~
             ~r/\A\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3} INFO  \[PlaybackController\] sid=a3f09c1e first\z/

    assert second =~ "WARN  [P2P] sid=a3f09c1e second"
  end

  test "finds a device by name, ignoring case" do
    {:ok, :stream} = PlayerLogs.ingest(batch(records: [record_map(%{"t" => now_ms()})]))

    assert raw(%{"device" => "work macbook"}).status == 200
  end

  test "an ambiguous name is 409 and lists both devices" do
    other = "0b7d3c2e-1a4f-4e6b-9c8d-2f3e4a5b6c7d"
    {:ok, :stream} = PlayerLogs.ingest(batch(records: [record_map(%{"t" => now_ms()})]))

    {:ok, :stream} =
      PlayerLogs.ingest(
        batch(meta: [device_id: other], records: [record_map(%{"t" => now_ms()})])
      )

    conn = raw(%{"device" => "Work MacBook"})

    assert conn.status == 409
    assert conn.resp_body =~ device_id()
    assert conn.resp_body =~ other
  end

  test "an unknown device or code is 404" do
    assert raw(%{"device" => "Nobody"}).status == 404
    assert raw(%{"code" => "LOG-000000"}).status == 404
  end

  test "filters by level, tag, session and text" do
    t = now_ms()

    {:ok, :stream} =
      PlayerLogs.ingest(
        batch(
          records: [
            record_map(%{"t" => t - 4_000, "l" => "info", "tag" => "P2P", "msg" => "dialing"}),
            record_map(%{"t" => t - 3_000, "l" => "warn", "tag" => "P2P", "msg" => "Path lost"}),
            record_map(%{"t" => t - 2_000, "l" => "error", "tag" => "Auth", "msg" => "refused"}),
            record_map(%{
              "t" => t - 1_000,
              "l" => "warn",
              "tag" => "P2P",
              "msg" => "path lost",
              "sid" => "other"
            })
          ]
        )
      )

    assert length(lines(raw(%{"device" => device_id(), "level" => "warn"}))) == 1 + 3
    assert length(lines(raw(%{"device" => device_id(), "tag" => "P2P,Auth"}))) == 1 + 4
    assert length(lines(raw(%{"device" => device_id(), "session" => "other"}))) == 1 + 1
    assert length(lines(raw(%{"device" => device_id(), "grep" => "PATH LOST"}))) == 1 + 2
  end

  test "since and until take durations and ISO times" do
    t = now_ms()

    {:ok, :stream} =
      PlayerLogs.ingest(
        batch(
          records: [
            record_map(%{"t" => t - 3 * 3_600_000, "msg" => "old"}),
            record_map(%{"t" => t - 60_000, "msg" => "recent"})
          ]
        )
      )

    assert [_header, recent] = lines(raw(%{"device" => device_id()}))
    assert recent =~ "recent"

    assert length(lines(raw(%{"device" => device_id(), "since" => "4h"}))) == 1 + 2

    until = (t - 3_600_000) |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

    assert [_header, old] =
             lines(raw(%{"device" => device_id(), "since" => "4h", "until" => until}))

    assert old =~ "old"
  end

  test "a report prints its header and every line, whatever its age" do
    {:ok, {:report, code}} =
      PlayerLogs.ingest(batch(meta: [kind: "report", note: "Subtitles vanish"]))

    assert [header, line] = lines(raw(%{"code" => code}))
    assert header =~ "# report #{code} from Work MacBook"
    assert header =~ "Subtitles vanish"
    assert line =~ "Opened the stream"
  end

  test "caps the output and says so" do
    put_logs_config(:raw_max_lines, 2)
    t = now_ms()

    {:ok, :stream} =
      PlayerLogs.ingest(batch(records: for(i <- 1..3, do: record_map(%{"t" => t - i}))))

    assert [_header, _one, _two, "-- truncated --"] = lines(raw(%{"device" => device_id()}))
  end

  test "unreadable parameters are 400" do
    assert raw(%{"device" => device_id(), "since" => "yesterday"}).status == 400
    assert raw(%{}).status == 400
  end
end
