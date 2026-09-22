defmodule MetadataRelay.PlayerLogs.QueryTest do
  use ExUnit.Case, async: true

  alias MetadataRelay.PlayerLogs.Query

  # 2026-09-22 14:03:12.345 UTC.
  @now 1_790_085_792_345

  test "a device query defaults to the last hour" do
    assert {:ok, %Query{device: "Work MacBook", code: nil, since_ms: since, until_ms: nil}} =
             Query.parse(%{"device" => "Work MacBook"}, @now)

    assert since == @now - 3_600_000
  end

  test "a code query has no default window and is upcased" do
    assert {:ok, %Query{code: "LOG-7K2QX9", device: nil, since_ms: nil}} =
             Query.parse(%{"code" => "log-7k2qx9"}, @now)
  end

  test "reads durations and ISO 8601 times" do
    assert Query.time("30s", @now) == {:ok, @now - 30_000}
    assert Query.time("30m", @now) == {:ok, @now - 1_800_000}
    assert Query.time("2h", @now) == {:ok, @now - 7_200_000}
    assert Query.time("3d", @now) == {:ok, @now - 259_200_000}
    assert Query.time("2026-09-22T14:03:12.345Z", @now) == {:ok, @now}
    assert Query.time(nil, @now) == {:ok, nil}
  end

  test "rejects a missing target, an unreadable time and an unknown level" do
    assert {:error, _message} = Query.parse(%{}, @now)
    assert {:error, message} = Query.parse(%{"device" => "x", "since" => "yesterday"}, @now)
    assert message =~ "yesterday"
    assert {:error, _message} = Query.parse(%{"device" => "x", "level" => "loud"}, @now)
  end

  test "splits tags on commas" do
    assert {:ok, %Query{tags: ["P2P", "iroh::magicsock"]}} =
             Query.parse(%{"device" => "x", "tag" => "P2P, iroh::magicsock"}, @now)
  end

  test "matches? applies every filter" do
    {:ok, query} =
      Query.parse(
        %{
          "device" => "x",
          "since" => "1h",
          "level" => "warn",
          "tag" => "P2P",
          "session" => "a3f09c1e",
          "grep" => "LOST"
        },
        @now
      )

    record = %{
      "t" => @now - 1_000,
      "l" => "warn",
      "tag" => "P2P",
      "msg" => "path lost",
      "sid" => "a3f09c1e"
    }

    assert Query.matches?(record, query)
    assert Query.matches?(%{record | "l" => "error"}, query)
    refute Query.matches?(%{record | "t" => @now - 7_200_000}, query)
    refute Query.matches?(%{record | "l" => "info"}, query)
    refute Query.matches?(%{record | "tag" => "Auth"}, query)
    refute Query.matches?(%{record | "sid" => "other"}, query)
    refute Query.matches?(%{record | "msg" => "path found"}, query)
    refute Query.matches?(nil, query)
  end

  test "formats a record like journalctl" do
    record = %{
      "t" => @now,
      "l" => "warn",
      "tag" => "P2P",
      "msg" => "path lost",
      "sid" => "a3f09c1e"
    }

    assert IO.iodata_to_binary(Query.format_line(record)) ==
             "2026-09-22 14:03:12.345 WARN  [P2P] sid=a3f09c1e path lost\n"
  end
end
