defmodule Mydia.Downloads.ObservedUploadRecordTest do
  use Mydia.DataCase, async: false

  import Mydia.DownloadsFixtures

  alias Mydia.Downloads.{Download, ObservedUpload}
  alias Mydia.Downloads.Structs.EnrichedDownload
  alias Mydia.Repo

  @t0 ~U[2031-05-10 12:00:00Z]

  defp row(download, attrs) do
    struct!(
      %EnrichedDownload{
        title: "Fictional Copper Lagoon",
        download_client: "rqbit",
        status: "seeding",
        id: download.id,
        metadata: download.metadata,
        uploaded_session_only?: true,
        in_client?: true,
        status_as_of: nil,
        live_uploaded: 0,
        uploaded: 0,
        ratio: 0.0,
        size: 500
      },
      attrs
    )
  end

  # The stored totals, without the `"seen_at"` stamp.
  defp entry(download) do
    case Repo.get!(Download, download.id).metadata["observed_upload"] do
      nil -> nil
      stored -> Map.take(stored, ["bytes", "session"])
    end
  end

  test "banks the live counter and returns the row overlaid" do
    download = download_fixture(%{metadata: %{}})

    [recorded] = ObservedUpload.record([row(download, %{live_uploaded: 300})], @t0)

    assert entry(download) == %{"bytes" => 300, "session" => 300}
    assert recorded.uploaded == 300

    assert recorded.metadata["observed_upload"] ==
             %{"bytes" => 300, "session" => 300, "seen_at" => "2031-05-10T12:00:00Z"}
  end

  test "a pause after uploading keeps the total" do
    download =
      download_fixture(%{metadata: %{"observed_upload" => %{"bytes" => 1000, "session" => 1000}}})

    [recorded] = ObservedUpload.record([row(download, %{live_uploaded: 0})], @t0)

    assert entry(download) == %{"bytes" => 1000, "session" => 0}
    assert recorded.uploaded == 1000
    assert recorded.ratio == 2.0
  end

  test "recording an overlaid row twice does not double count" do
    download = download_fixture(%{metadata: %{}})

    first = ObservedUpload.record([row(download, %{live_uploaded: 400})], @t0)
    [second] = ObservedUpload.record(first, @t0)

    assert entry(download) == %{"bytes" => 400, "session" => 400}
    assert second.uploaded == 400
  end

  test "an out-of-order pass credits nothing" do
    download = download_fixture(%{metadata: %{}})
    t1 = DateTime.add(@t0, 120, :second)

    ObservedUpload.record([row(download, %{live_uploaded: 150})], t1)
    # An overlapping pass that read the client earlier writes after the later one.
    ObservedUpload.record([row(download, %{live_uploaded: 100})], @t0)

    assert %{"bytes" => 150, "session" => 150} = entry(download)

    ObservedUpload.record([row(download, %{live_uploaded: 200})], DateTime.add(t1, 120, :second))
    assert %{"bytes" => 200, "session" => 200} = entry(download)
  end

  test "a rejected pass returns the stored total, not its own counter stepped" do
    download = download_fixture(%{metadata: %{}})

    ObservedUpload.record([row(download, %{live_uploaded: 200})], DateTime.add(@t0, 120, :second))
    [rejected] = ObservedUpload.record([row(download, %{live_uploaded: 150})], @t0)

    assert rejected.uploaded == 200
    assert rejected.ratio == 0.4
  end

  test "orders by when the counter was read, not when the pass started" do
    download = download_fixture(%{metadata: %{}})

    # Pass A started first but read the client last (200); pass B started
    # later, read earlier (100), and writes after A.
    ObservedUpload.record(
      [row(download, %{live_uploaded: 200, live_uploaded_at: ~U[2031-05-10 12:00:05Z]})],
      ~U[2031-05-10 12:00:00Z]
    )

    [b] =
      ObservedUpload.record(
        [row(download, %{live_uploaded: 100, live_uploaded_at: ~U[2031-05-10 12:00:03Z]})],
        ~U[2031-05-10 12:00:01Z]
      )

    assert entry(download) == %{"bytes" => 200, "session" => 200}
    assert b.uploaded == 200
  end

  test "passes in the same second are still ordered" do
    download = download_fixture(%{metadata: %{}})
    newer = ~U[2031-05-10 12:00:00.800000Z]

    ObservedUpload.record([row(download, %{live_uploaded: 200})], newer)
    ObservedUpload.record([row(download, %{live_uploaded: 100})], ~U[2031-05-10 12:00:00.100000Z])
    assert entry(download) == %{"bytes" => 200, "session" => 200}

    # A later pass in the same second with a lower counter is a real reset.
    ObservedUpload.record([row(download, %{live_uploaded: 50})], ~U[2031-05-10 12:00:00.900000Z])
    assert entry(download) == %{"bytes" => 250, "session" => 50}
  end

  test "skips unflagged, stale and not-in-client rows" do
    rows =
      for attrs <- [
            %{uploaded_session_only?: false},
            %{status_as_of: @t0},
            %{in_client?: false}
          ] do
        download = download_fixture(%{metadata: %{}})
        {download, row(download, Map.put(attrs, :live_uploaded, 300))}
      end

    assert ObservedUpload.record(Enum.map(rows, &elem(&1, 1)), @t0) ==
             Enum.map(rows, &elem(&1, 1))

    for {download, _row} <- rows, do: assert(entry(download) == nil)
  end

  test "writes nothing when the entry is unchanged, and keeps other keys" do
    download =
      download_fixture(%{
        metadata: %{
          "observed_upload" => %{"bytes" => 300, "session" => 300},
          "observed_seeding" => %{"seconds" => 60, "last_seen_at" => nil}
        }
      })

    handler = "observed-upload-record-test-#{System.unique_integer()}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:mydia, :repo, :query],
      fn _event, _measurements, %{query: query}, _config ->
        if query =~ ~r/^UPDATE/i, do: send(test_pid, {:update, query})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    ObservedUpload.record([row(download, %{live_uploaded: 300})], @t0)
    refute_received {:update, _query}

    ObservedUpload.record([row(download, %{live_uploaded: 350})], @t0)
    assert_received {:update, _query}

    metadata = Repo.get!(Download, download.id).metadata
    assert entry(download) == %{"bytes" => 350, "session" => 350}
    assert metadata["observed_seeding"] == %{"seconds" => 60, "last_seen_at" => nil}
  end

  test "one failing row does not stop the others" do
    download = download_fixture(%{metadata: %{}})
    failing = row(%Download{id: nil, metadata: %{}}, %{live_uploaded: 10})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert [^failing, recorded] =
                 ObservedUpload.record([failing, row(download, %{live_uploaded: 20})], @t0)

        assert recorded.uploaded == 20
      end)

    assert log =~ "Recording observed upload failed"
    assert entry(download) == %{"bytes" => 20, "session" => 20}
  end
end
