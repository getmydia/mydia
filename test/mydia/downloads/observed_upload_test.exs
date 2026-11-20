defmodule Mydia.Downloads.ObservedUploadTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.ObservedUpload
  alias Mydia.Downloads.Structs.{DownloadStatus, EnrichedDownload}

  describe "step/2" do
    test "first sight counts the current session in full" do
      assert ObservedUpload.step(nil, 500) == %{"bytes" => 500, "session" => 500}
    end

    test "adds growth within a session" do
      assert ObservedUpload.step(%{"bytes" => 500, "session" => 500}, 800) ==
               %{"bytes" => 800, "session" => 800}
    end

    test "a lower counter is a new session and adds in full" do
      assert ObservedUpload.step(%{"bytes" => 800, "session" => 800}, 100) ==
               %{"bytes" => 900, "session" => 100}
    end

    test "a reset to 0 while paused keeps the total" do
      assert ObservedUpload.step(%{"bytes" => 800, "session" => 800}, 0) ==
               %{"bytes" => 800, "session" => 0}
    end

    test "a malformed entry is treated as none" do
      assert ObservedUpload.step(%{"bytes" => "x"}, 50) == %{"bytes" => 50, "session" => 50}

      assert ObservedUpload.step(%{"bytes" => -1, "session" => 0}, 50) ==
               %{"bytes" => 50, "session" => 50}
    end
  end

  describe "step/3" do
    @at ~U[2031-05-10 12:00:00.800000Z]

    test "a malformed non-map entry is replaced, not raised on" do
      assert %{"bytes" => 50, "session" => 50, "seen_at" => _} =
               ObservedUpload.step("bad", 50, @at)
    end

    test "stamps seen_at at full precision" do
      assert ObservedUpload.step(nil, 50, @at)["seen_at"] == "2031-05-10T12:00:00.800000Z"
    end
  end

  test "total/2 agrees with step/2" do
    entry = %{"bytes" => 800, "session" => 800}

    for live <- [0, 100, 800, 1200] do
      assert ObservedUpload.total(entry, live) == ObservedUpload.step(entry, live)["bytes"]
    end
  end

  describe "overlay/1" do
    defp row(attrs \\ %{}) do
      struct!(
        %EnrichedDownload{
          id: "d1",
          title: "Fictional Copper Lagoon",
          download_client: "rqbit",
          status: "seeding",
          uploaded_session_only?: true,
          in_client?: true,
          status_as_of: nil,
          live_uploaded: 0,
          uploaded: 0,
          ratio: 0.0,
          size: 1000,
          metadata: %{"observed_upload" => %{"bytes" => 2000, "session" => 2000}}
        },
        attrs
      )
    end

    test "a paused rqbit row keeps the banked total and ratio" do
      assert %{uploaded: 2000, ratio: 2.0, live_uploaded: 0} = ObservedUpload.overlay(row())
    end

    test "an unflagged row is unchanged" do
      row = row(%{uploaded_session_only?: false})
      assert ObservedUpload.overlay(row) == row
    end

    test "a not-in-client row is unchanged" do
      gone = row(%{in_client?: false})
      assert ObservedUpload.overlay(gone) == gone
    end

    test "a stale row adds only growth, never reading an older counter as a reset" do
      stale = row(%{status_as_of: ~U[2031-05-10 12:00:00Z]})

      # A cached counter older than the stored session is not a new session.
      assert %{uploaded: 2000, ratio: 2.0} = ObservedUpload.overlay(%{stale | live_uploaded: 150})
      assert %{uploaded: 2500} = ObservedUpload.overlay(%{stale | live_uploaded: 2500})

      assert %{uploaded: 150} =
               ObservedUpload.overlay(%{stale | metadata: nil, live_uploaded: 150})
    end

    test "a stale snapshot read before the stored entry adds nothing" do
      # Paused after 2000 uploaded: the entry was recorded at 12:05 with session 0.
      metadata = %{
        "observed_upload" => %{
          "bytes" => 2000,
          "session" => 0,
          "seen_at" => "2031-05-10T12:05:00Z"
        }
      }

      stale =
        row(%{metadata: metadata, live_uploaded: 1500, status_as_of: ~U[2031-05-10 12:10:00Z]})

      # A pre-pause snapshot (read at 12:04) holds uploads already in `bytes`.
      assert %{uploaded: 2000} =
               ObservedUpload.overlay(%{stale | live_uploaded_at: ~U[2031-05-10 12:04:00Z]})

      # Without a read time, the snapshot's own date decides.
      assert %{uploaded: 2000} =
               ObservedUpload.overlay(%{stale | status_as_of: ~U[2031-05-10 12:04:00Z]})

      # A snapshot read after the entry holds new uploads.
      assert %{uploaded: 3500} =
               ObservedUpload.overlay(%{stale | live_uploaded_at: ~U[2031-05-10 12:06:00Z]})
    end

    test "size 0 or nil leaves the ratio as reported" do
      for size <- [0, nil] do
        overlaid = ObservedUpload.overlay(row(%{size: size}))
        assert overlaid.uploaded == 2000
        assert overlaid.ratio == 0.0
      end
    end

    test "nil metadata uses the live counter" do
      assert %{uploaded: 300, ratio: 0.3} =
               ObservedUpload.overlay(row(%{metadata: nil, live_uploaded: 300}))
    end
  end

  test "put_upload/2 carries the client's read time with the counter" do
    read_at = ~U[2031-05-10 12:00:03Z]

    status = %DownloadStatus{
      id: "h",
      name: "n",
      state: :seeding,
      progress: 100.0,
      uploaded: 300,
      ratio: 0.3,
      size: 1000,
      uploaded_session_only?: true,
      observed_at: read_at
    }

    row =
      ObservedUpload.put_upload(
        %EnrichedDownload{
          id: "d1",
          title: "Fictional Copper Lagoon",
          download_client: "rqbit",
          status: "seeding",
          in_client?: true,
          metadata: %{}
        },
        status
      )

    assert row.live_uploaded == 300
    assert row.live_uploaded_at == read_at
  end

  test "overlay_status/2 applies to a flagged DownloadStatus" do
    status =
      DownloadStatus.new(%{
        id: "h",
        name: "n",
        state: :paused,
        progress: 100.0,
        uploaded: 0,
        ratio: 0.0,
        size: 1000,
        uploaded_session_only?: true
      })

    meta = %{"observed_upload" => %{"bytes" => 1500, "session" => 1500}}

    assert %{uploaded: 1500, ratio: 1.5} = ObservedUpload.overlay_status(status, meta)

    assert ObservedUpload.overlay_status(%{status | uploaded_session_only?: false}, meta).ratio ==
             0.0
  end
end
