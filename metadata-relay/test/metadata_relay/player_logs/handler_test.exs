defmodule MetadataRelay.PlayerLogs.HandlerTest do
  use ExUnit.Case, async: false

  import MetadataRelay.PlayerLogsHelpers

  alias MetadataRelay.{RateLimiter, Repo, Router}
  alias MetadataRelay.PlayerLogs.{Chunk, Device}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    case GenServer.whereis(RateLimiter) do
      nil -> start_supervised!(RateLimiter)
      _pid -> :ok
    end

    :ets.delete_all_objects(:rate_limiter)
    use_tmp_logs_dir()
    :ok
  end

  defp post_logs(body) do
    Plug.Test.conn(:post, "/player-logs", body)
    |> Plug.Conn.put_req_header("content-type", "application/x-ndjson")
    |> Plug.Conn.put_req_header("content-encoding", "gzip")
    |> Router.call([])
  end

  defp exhaust(key, limit) do
    for _ <- 1..limit, do: RateLimiter.check_rate_limit(key, limit: limit, window_ms: 60_000)
  end

  test "a stream batch is stored and answered with 204" do
    conn = post_logs(gz_body([meta_map(), record_map()]))

    assert conn.status == 204
    assert [%Chunk{kind: "stream"}] = Repo.all(Chunk)
  end

  test "a report is answered with 201 and its code" do
    conn =
      post_logs(
        gz_body([meta_map(%{"kind" => "report", "note" => "Audio drifts"}), record_map()])
      )

    assert conn.status == 201
    assert %{"code" => code} = Jason.decode!(conn.resp_body)
    assert code =~ ~r/\ALOG-[0-9A-HJKMNP-TV-Z]{6}\z/
  end

  test "a body over 1 MB compressed is 413" do
    conn = post_logs(:crypto.strong_rand_bytes(1_048_577))
    assert conn.status == 413
  end

  test "a body that inflates past 8 MB is 413" do
    conn = post_logs(:zlib.gzip(:binary.copy("a", 9 * 1024 * 1024)))
    assert conn.status == 413
  end

  test "a bad meta line, bad gzip or no records is 400" do
    assert post_logs(gz_body([record_map(), record_map()])).status == 400
    assert post_logs("not gzip").status == 400
    assert post_logs(gz_body([meta_map(), "garbage"])).status == 400
  end

  test "an unknown report code is 400" do
    body = gz_body([meta_map(%{"kind" => "report", "report" => "LOG-000000"}), record_map()])
    assert post_logs(body).status == 400
  end

  test "each device gets 30 batches a minute" do
    exhaust("player_logs:device:#{device_id()}", 30)

    conn = post_logs(gz_body([meta_map(), record_map()]))

    assert conn.status == 429
    assert Plug.Conn.get_resp_header(conn, "retry-after") == ["60"]
  end

  test "each address gets 120 batches a minute, before anything is decompressed" do
    exhaust("player_logs:ip:127.0.0.1", 120)

    conn = post_logs("not even gzip")

    assert conn.status == 429
    assert Plug.Conn.get_resp_header(conn, "retry-after") == ["60"]
  end

  test "the daily quota answers 429 with Retry-After until midnight UTC" do
    Repo.insert!(%Device{
      device_id: device_id(),
      first_seen_at: DateTime.utc_now() |> DateTime.truncate(:second),
      last_seen_at: DateTime.utc_now() |> DateTime.truncate(:second),
      bytes_today: 50 * 1024 * 1024,
      bytes_day: Date.utc_today()
    })

    conn = post_logs(gz_body([meta_map(), record_map()]))

    assert conn.status == 429
    assert [seconds] = Plug.Conn.get_resp_header(conn, "retry-after")
    assert String.to_integer(seconds) in 1..86_400
  end
end
