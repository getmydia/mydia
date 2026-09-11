defmodule Mydia.Downloads.HistoryFilterTest do
  @moduledoc """
  The zero-client branch must apply the requested filter to database-derived status.
  """
  use Mydia.DataCase, async: false

  # Every zero-client test here hits History's "No download clients configured"
  # warning by design; silence it instead of drowning real failures in noise.
  @moduletag :capture_log

  import Mydia.Factory

  alias Mydia.Downloads

  test "filter: :active excludes an imported download when no client is configured" do
    assert Mydia.Settings.list_download_client_configs() == []

    insert(:download,
      title: "Already here",
      imported_at: DateTime.utc_now(),
      completed_at: DateTime.utc_now()
    )

    insert(:download, title: "Still moving", download_client: nil, download_client_id: nil)

    titles = Downloads.list_downloads_with_status(filter: :active) |> Enum.map(& &1.title)

    assert "Already here" not in titles
    assert "Still moving" in titles
  end

  test "filter: :all still returns every row when no client is configured" do
    insert(:download, title: "Already here", imported_at: DateTime.utc_now())

    titles = Downloads.list_downloads_with_status(filter: :all) |> Enum.map(& &1.title)

    assert "Already here" in titles
  end
end
