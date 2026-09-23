defmodule MetadataRelayWeb.LogsLiveTest do
  use ExUnit.Case, async: false

  import MetadataRelay.PlayerLogsHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn

  alias MetadataRelay.{PlayerLogs, Repo}

  @endpoint MetadataRelayWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    use_tmp_logs_dir()
    :ok
  end

  defp authed_conn do
    build_conn()
    |> put_req_header("authorization", "Basic " <> Base.encode64("admin:admin"))
  end

  test "requires the dashboard credentials" do
    assert build_conn() |> get("/logs") |> Map.get(:status) == 401
  end

  test "shows an empty state before any device has sent logs" do
    {:ok, view, _html} = live(authed_conn(), "/logs")

    assert has_element?(view, "#logs-dashboard")
    assert has_element?(view, "#logs-devices-empty")
  end

  test "lists devices, marks one that streamed recently, and lists reports" do
    report_only_id = "0b7d3c2e-1a4f-4e6b-9c8d-2f3e4a5b6c7d"

    {:ok, :stream} = PlayerLogs.ingest(batch())

    {:ok, {:report, code}} =
      PlayerLogs.ingest(batch(meta: [kind: "report", note: "Audio drifts"]))

    {:ok, {:report, _code}} =
      PlayerLogs.ingest(
        batch(meta: [device_id: report_only_id, device_name: "Living Room TV", kind: "report"])
      )

    {:ok, view, _html} = live(authed_conn(), "/logs")

    assert has_element?(view, "#log-device-#{device_id()}")
    assert has_element?(view, "#log-device-#{device_id()} .badge-success")
    assert has_element?(view, "#log-device-#{report_only_id}")
    refute has_element?(view, "#log-device-#{report_only_id} .badge-success")
    assert has_element?(view, "#log-report-#{code}")
    assert has_element?(view, "#log-report-#{code} a[href='/logs/raw?code=#{code}']")
  end

  test "the device page lists sessions, newest first" do
    {:ok, :stream} =
      PlayerLogs.ingest(
        batch(
          records: [
            record_map(%{"t" => 1_000, "sid" => "s1"}),
            record_map(%{"t" => 2_000, "sid" => "s1"}),
            record_map(%{"t" => 5_000, "sid" => "s2"})
          ]
        )
      )

    {:ok, view, html} = live(authed_conn(), "/logs/devices/#{device_id()}")

    assert has_element?(view, "#log-device-page")
    assert has_element?(view, "#log-session-s1")
    assert has_element?(view, "#log-session-s2")
    assert :binary.match(html, "log-session-s2") < :binary.match(html, "log-session-s1")
  end

  test "an unknown device goes back to the list" do
    assert {:error, {:live_redirect, %{to: "/logs"}}} =
             live(authed_conn(), "/logs/devices/no-such-device")
  end
end
