defmodule MetadataRelay.IngestRejectionTest do
  # Every rejected ingest request must leave a log line saying why and who sent
  # it, plus a counter by reason. Without them a stream of 400s reads only as
  # "POST /crashes/report ... Sent 400" and the cause has to be dug out of the
  # ingress access log.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint MetadataRelayWeb.Endpoint
  @metric "metadata_relay_ingest_rejected_total"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(MetadataRelay.Repo)
    :ets.delete_all_objects(:rate_limiter)
    :ok
  end

  defp post_json(path, body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("user-agent", "probe/1.0")
    |> put_req_header("cf-connecting-ip", "2001:db8::1")
    # Plug.Test does not set it; every real HTTP client does.
    |> put_req_header("content-length", Integer.to_string(byte_size(body)))
    |> post(path, body)
  end

  defp count(endpoint, reason) do
    key = {@metric, Enum.sort(endpoint: endpoint, reason: reason)}

    case :ets.lookup(:metrics_counters, key) do
      [{^key, n}] -> n
      [] -> 0
    end
  end

  describe "POST /crashes/report" do
    test "a body missing required fields is logged with its reason and caller, and counted" do
      before = count("crash_reports", "validation")
      body = ~s({"stacktrace":[],"source":"player","version":"9.9.9"})

      log = capture_log(fn -> assert post_json("/crashes/report", body).status == 400 end)

      assert count("crash_reports", "validation") == before + 1
      assert log =~ "[Ingest] rejected"
      assert log =~ "endpoint=crash_reports"
      assert log =~ "status=400"
      assert log =~ "reason=validation"
      assert log =~ "Missing required field: error_type"
      assert log =~ "bytes=#{byte_size(body)}"
      assert log =~ ~s(user_agent="probe/1.0")
      assert log =~ ~s(cf_connecting_ip="2001:db8::1")
      assert log =~ ~s(source="player")
      assert log =~ ~s(version="9.9.9")
    end

    test "the log line never carries the report body" do
      body = ~s({"error_message":"token=SECRET123","stacktrace":"nope"})

      log = capture_log(fn -> assert post_json("/crashes/report", body).status == 400 end)

      assert log =~ "reason=validation"
      refute log =~ "SECRET123"
    end

    test "malformed JSON is a 400 with a JSON body, logged and counted as not_json" do
      before = count("crash_reports", "not_json")

      log =
        capture_log(fn ->
          assert {400, _headers, resp} =
                   assert_error_sent(400, fn -> post_json("/crashes/report", "not json") end)

          assert %{"error" => "Invalid JSON"} = Jason.decode!(resp)
        end)

      assert count("crash_reports", "not_json") == before + 1
      assert log =~ "reason=not_json"
      assert log =~ ~s(user_agent="probe/1.0")
    end

    test "a rate-limited report is counted" do
      before = count("crash_reports", "rate_limited")
      body = ~s({"stacktrace":[]})

      capture_log(fn ->
        statuses = for _ <- 1..11, do: post_json("/crashes/report", body).status
        assert List.last(statuses) == 429
      end)

      assert count("crash_reports", "rate_limited") == before + 1
    end
  end

  describe "POST /feedback" do
    test "a body missing required fields is logged and counted" do
      before = count("feedback", "validation")

      log =
        capture_log(fn ->
          assert post_json("/feedback", ~s({"type":"bug"})).status == 400
        end)

      assert count("feedback", "validation") == before + 1
      assert log =~ "endpoint=feedback"
      assert log =~ "Missing required field: message"
    end

    test "an over-long message is counted as message_too_long without logging the message" do
      before = count("feedback", "message_too_long")
      message = String.duplicate("SECRET", 700)

      log =
        capture_log(fn ->
          body = Jason.encode!(%{"type" => "bug", "message" => message})
          assert post_json("/feedback", body).status == 400
        end)

      assert count("feedback", "message_too_long") == before + 1
      refute log =~ "SECRETSECRET"
    end
  end

  test "a malformed JSON body on another route is counted under other" do
    before = count("other", "not_json")

    capture_log(fn ->
      assert_error_sent(400, fn -> post_json("/api/v1/subtitles/search", "{oops") end)
    end)

    assert count("other", "not_json") == before + 1
  end
end
