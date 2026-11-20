defmodule Mydia.Downloads.ObservedUploadTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.ObservedUpload
  alias Mydia.Downloads.Structs.DownloadStatus

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

  test "total/2 agrees with step/2" do
    entry = %{"bytes" => 800, "session" => 800}

    for live <- [0, 100, 800, 1200] do
      assert ObservedUpload.total(entry, live) == ObservedUpload.step(entry, live)["bytes"]
    end
  end

  describe "overlay/1" do
    defp row(attrs \\ %{}) do
      Map.merge(
        %{
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

    test "a stale or not-in-client row is unchanged" do
      stale = row(%{status_as_of: ~U[2031-05-10 12:00:00Z]})
      gone = row(%{in_client?: false})

      assert ObservedUpload.overlay(stale) == stale
      assert ObservedUpload.overlay(gone) == gone
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
