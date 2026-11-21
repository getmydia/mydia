defmodule Mydia.Downloads.HistoryObservedUploadTest do
  # Not async: swaps an adapter in the global client registry.
  use Mydia.DataCase, async: false

  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Downloads
  alias Mydia.Downloads.Client.Registry
  alias Mydia.Downloads.ListStatusAdapter, as: ListAdapter
  alias Mydia.Downloads.Structs.DownloadStatus

  @hash "6666666666666666666666666666666666666666"

  setup do
    original = Registry.lookup(:rqbit)
    Registry.register(:rqbit, ListAdapter)

    on_exit(fn ->
      ListAdapter.clear()
      if original, do: Registry.register(:rqbit, original)
    end)

    client = download_client_config_fixture(%{type: "rqbit"})
    media_item = media_item_fixture(%{title: "Fictional Copper Lagoon"})

    download_fixture(%{
      media_item_id: media_item.id,
      download_client: client.name,
      download_client_id: @hash,
      metadata: %{"observed_upload" => %{"bytes" => 2000, "session" => 2000}}
    })

    :ok
  end

  defp paused(session_only?) do
    %DownloadStatus{
      id: @hash,
      name: "Fictional Copper Lagoon",
      state: :paused,
      progress: 100.0,
      uploaded: 0,
      ratio: 0.0,
      size: 1000,
      uploaded_session_only?: session_only?
    }
  end

  test "a paused rqbit torrent reads its banked total" do
    ListAdapter.put([paused(true)])

    [row] = Downloads.list_downloads_with_status(filter: :all)

    assert row.uploaded == 2000
    assert row.ratio == 2.0
    assert row.live_uploaded == 0
    assert row.uploaded_session_only? == true
  end

  test "an unflagged client's counter is shown as reported" do
    ListAdapter.put([paused(false)])

    [row] = Downloads.list_downloads_with_status(filter: :all)

    assert row.uploaded == 0
    assert row.uploaded_session_only? == false
  end
end
