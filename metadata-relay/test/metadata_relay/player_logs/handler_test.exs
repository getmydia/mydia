defmodule MetadataRelay.PlayerLogs.HandlerTest do
  use ExUnit.Case, async: false

  import MetadataRelay.PlayerLogsHelpers

  alias MetadataRelay.{RateLimiter, Repo, Router}
  alias MetadataRelay.PlayerLogs.{Chunk, Device, ReportBudget}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    case GenServer.whereis(RateLimiter) do
      nil -> start_supervised!(RateLimiter)
      _pid -> :ok
    end

    case GenServer.whereis(ReportBudget) do
      nil -> start_supervised!(ReportBudget)
      _pid -> :ok
    end

    :ets.delete_all_objects(:rate_limiter)
    :ets.delete_all_objects(:player_logs_report_budget)
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

  # The exact decompressed byte count the handler will charge for `lines`,
  # mirroring what `gz_body/1` compresses (and `Ingest.decode/2` measures),
  # so budget tests can set an exact boundary instead of guessing a round
  # number.
  defp decompressed_size(lines) do
    lines
    |> Enum.map_join("\n", fn
      line when is_binary(line) -> line
      map -> Jason.encode!(map)
    end)
    |> Kernel.<>("\n")
    |> byte_size()
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

  test "a report over the per-address daily budget is rejected with 429 and Retry-After" do
    lines = [meta_map(%{"kind" => "report"}), record_map()]
    put_logs_config(:report_budget_bytes, decompressed_size(lines) - 1)

    conn = post_logs(gz_body(lines))

    assert conn.status == 429
    assert [seconds] = Plug.Conn.get_resp_header(conn, "retry-after")
    assert String.to_integer(seconds) in 1..86_400
  end

  test "the report budget is shared across devices behind the same address" do
    lines = [meta_map(%{"kind" => "report"}), record_map()]
    put_logs_config(:report_budget_bytes, decompressed_size(lines) + 10)

    first = post_logs(gz_body(lines))
    assert first.status == 201

    other_device_lines = [
      meta_map(%{"kind" => "report", "device_id" => Ecto.UUID.generate()}),
      record_map()
    ]

    second = post_logs(gz_body(other_device_lines))

    assert second.status == 429
    assert [seconds] = Plug.Conn.get_resp_header(second, "retry-after")
    assert String.to_integer(seconds) in 1..86_400
  end

  test "stream batches are not limited by the report budget" do
    put_logs_config(:report_budget_bytes, 0)

    conn = post_logs(gz_body([meta_map(), record_map()]))

    assert conn.status == 204
  end

  test "a batch that fails validation is not charged against the report budget" do
    bad_lines = [meta_map(%{"kind" => "report", "report" => "LOG-000000"}), record_map()]
    good_lines = [meta_map(%{"kind" => "report"}), record_map()]
    bad_size = decompressed_size(bad_lines)
    good_size = decompressed_size(good_lines)
    # Big enough for either batch alone, too small for both: if the failed
    # first batch were wrongly charged, the second (valid) batch would tip
    # the address over budget and get 429 instead of 201.
    put_logs_config(:report_budget_bytes, max(bad_size, good_size) + 5)

    assert post_logs(gz_body(bad_lines)).status == 400

    conn = post_logs(gz_body(good_lines))
    assert conn.status == 201
  end

  describe "concurrent report budget reservations" do
    # A large enough batch that the real gzip decode and file write between
    # ReportBudget.reserve/3 and PlayerLogs.ingest/1 completing give
    # concurrent uploads room to interleave.
    defp wide_report_lines(device_id) do
      now_ms = System.os_time(:millisecond)
      records = for i <- 1..8_000, do: record_map(%{"t" => now_ms + i})
      [meta_map(%{"kind" => "report", "device_id" => device_id}) | records]
    end

    defp post_logs_concurrently(body) do
      parent = self()

      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
        post_logs(body)
      end)
    end

    test "concurrent report uploads never jointly exceed the remaining budget" do
      count = 10
      size = decompressed_size(wide_report_lines(Ecto.UUID.generate()))
      put_logs_config(:report_budget_bytes, size * 2)

      bodies = for _ <- 1..count, do: gz_body(wide_report_lines(Ecto.UUID.generate()))

      results =
        bodies
        |> Enum.map(&post_logs_concurrently/1)
        |> Enum.map(&Task.await(&1, 10_000))

      statuses = Enum.map(results, & &1.status)
      accepted = Enum.count(statuses, &(&1 == 201))
      rejected = Enum.count(statuses, &(&1 == 429))

      assert accepted + rejected == count

      # The budget covers exactly two batches of `size` bytes. A check read
      # before another upload's charge lands lets more than two through,
      # which is exactly the bug this guards against.
      assert accepted == 2,
             "a stale-read check let more than 2 reports fit a 2x-size budget: got #{accepted}"
    end

    test "a failed ingest releases the report budget reservation" do
      lines = [meta_map(%{"kind" => "report", "report" => "LOG-000000"}), record_map()]
      put_logs_config(:report_budget_bytes, decompressed_size(lines) + 100)

      assert post_logs(gz_body(lines)).status == 400

      # If ingest's failure hadn't released the reservation, the address's
      # tally would still read the batch's size instead of having been put
      # back to zero.
      assert :ets.lookup(:player_logs_report_budget, "127.0.0.1") ==
               [{"127.0.0.1", Date.utc_today(), 0}]
    end
  end
end
