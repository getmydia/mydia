defmodule MetadataRelay.PlayerLogs.IngestTest do
  use ExUnit.Case, async: true

  import MetadataRelay.PlayerLogsHelpers

  alias MetadataRelay.PlayerLogs.{Batch, Ingest, Meta}

  @limit 8 * 1024 * 1024

  test "decodes the meta line and every valid record" do
    assert {:ok, %Batch{meta: %Meta{} = meta, records: [record], dropped: 0} = batch} =
             Ingest.decode(gz_body([meta_map(), record_map()]), @limit)

    assert meta.device_id == device_id()
    assert meta.kind == "stream"
    assert meta.device_name == "Work MacBook"
    assert meta.report == nil
    assert record.t == record_map()["t"]
    assert record.sid == "a3f09c1e"
    assert Jason.decode!(record.line) == record_map()
    assert batch.size > 0
  end

  test "drops records that do not validate and counts them" do
    lines = [
      meta_map(),
      record_map(),
      "not json",
      record_map(%{"l" => "loud"}),
      record_map(%{"t" => "yesterday"}),
      Map.delete(record_map(), "msg")
    ]

    assert {:ok, %Batch{records: [_], dropped: 4}} = Ingest.decode(gz_body(lines), @limit)
  end

  test "drops records whose t is outside the sane epoch millisecond range" do
    min_t_ms = DateTime.to_unix(~U[2000-01-01 00:00:00Z], :millisecond)
    too_old = record_map(%{"t" => min_t_ms - 1})
    at_lower_bound = record_map(%{"t" => min_t_ms})
    too_far_future = record_map(%{"t" => System.os_time(:millisecond) + 2 * 86_400_000})

    lines = [meta_map(), too_old, at_lower_bound, too_far_future]

    assert {:ok, %Batch{records: [kept], dropped: 2}} = Ingest.decode(gz_body(lines), @limit)
    assert kept.t == min_t_ms
  end

  test "fills in defaults and caps long fields" do
    raw =
      record_map(%{
        "msg" => String.duplicate("x", 9000),
        "src" => "cobol",
        "sid" => String.duplicate("s", 40)
      })
      |> Map.delete("tag")

    assert {:ok, %Batch{records: [stored]}} = Ingest.decode(gz_body([meta_map(), raw]), @limit)

    decoded = Jason.decode!(stored.line)
    assert decoded["tag"] == "app"
    assert decoded["src"] == "dart"
    assert String.length(decoded["sid"]) == 32
    assert decoded["msg"] == String.duplicate("x", 8192) <> "...[truncated]"
  end

  test "rejects a body whose meta line is missing or malformed" do
    bad_first_lines = [
      record_map(),
      meta_map(%{"device_id" => "not-a-uuid"}),
      meta_map(%{"kind" => "live"}),
      meta_map(%{"report" => "LOG-0000I0"}),
      meta_map(%{"type" => "log"})
    ]

    for first <- bad_first_lines do
      assert Ingest.decode(gz_body([first, record_map()]), @limit) == {:error, :invalid_meta}
    end
  end

  test "accepts a report follow-up code" do
    body = gz_body([meta_map(%{"kind" => "report", "report" => "LOG-7K2QX9"}), record_map()])

    assert {:ok, %Batch{meta: %Meta{kind: "report", report: "LOG-7K2QX9"}}} =
             Ingest.decode(body, @limit)
  end

  test "rejects a body with no valid records" do
    assert Ingest.decode(gz_body([meta_map(), "garbage"]), @limit) == {:error, :no_records}
  end

  test "rejects a body that is not gzip, or is truncated" do
    assert Ingest.decode("plain text", @limit) == {:error, :invalid_gzip}

    gz = gz_body([meta_map(), record_map()])
    truncated = binary_part(gz, 0, byte_size(gz) - 8)
    assert Ingest.decode(truncated, @limit) == {:error, :invalid_gzip}
  end

  test "stops decompressing past the limit" do
    bomb = :zlib.gzip(:binary.copy("a", 20 * 1024 * 1024))
    assert byte_size(bomb) < 100_000
    assert Ingest.decode(bomb, @limit) == {:error, :too_large}
  end
end
