defmodule Mydia.Downloads.BlacklistsLogTest do
  # Sync: the info-level log needs the global Logger level raised, which an
  # async module could leak into its neighbours (see test/README.md).
  use Mydia.DataCase, async: false

  import ExUnit.CaptureLog

  alias Mydia.Downloads.Blacklists
  alias Mydia.Indexers.SearchResult

  setup do
    original_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: original_level) end)
    :ok
  end

  # A Cardigann guid is the download URL, so it can carry a tracker passkey.
  test "logs a rejected URL guid with its passkey redacted" do
    guid = "https://tracker.example/download.php?id=3&passkey=QUIETORCHARDSECRET"

    result = %SearchResult{
      title: "Quiet Orchard S01E01 1080p WEB",
      size: 1_073_741_824,
      seeders: 0,
      leechers: 0,
      download_url: guid,
      indexer: "LanternTracker",
      guid: guid
    }

    {:ok, _} = Blacklists.add(result.indexer, guid, result.title, "stalled")

    log =
      capture_log([level: :info, metadata: [:guid]], fn ->
        assert [] = Blacklists.reject_blacklisted([result])
      end)

    assert log =~ "Rejected blacklisted release"
    assert log =~ "download.php?id=3"
    refute log =~ "QUIETORCHARDSECRET"
  end

  # A ban kept under the legacy title-and-size key has no row for the result's
  # URL guid, so the log names the key a lookup will find.
  test "logs the legacy key when that is the one the ban matched" do
    result = %SearchResult{
      title: "Lantern Harbor S02E03 720p HDTV",
      size: 2_147_483_648,
      seeders: 0,
      leechers: 0,
      download_url: "https://tracker.example/download.php?id=9",
      indexer: "LanternTracker",
      guid: "https://tracker.example/download.php?id=9"
    }

    [primary, legacy] = Blacklists.release_guids(result)
    {:ok, _} = Blacklists.add(result.indexer, legacy, result.title, "stalled")

    log =
      capture_log([level: :info, metadata: [:guid, :matched_by]], fn ->
        assert [] = Blacklists.reject_blacklisted([result])
      end)

    assert log =~ "guid=#{legacy}"
    refute log =~ primary
  end
end
