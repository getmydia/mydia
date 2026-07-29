defmodule MydiaWeb.MediaLive.Show.HelpersStatusTest do
  use ExUnit.Case, async: true

  import MydiaWeb.MediaLive.Show.Helpers, only: [get_download_status: 1]

  defp d(attrs) do
    Map.merge(
      %{status: "missing", download_client_id: "abc", error_message: nil, title: "t"},
      attrs
    )
  end

  test "prefers in-client active statuses over grabbing" do
    grabbing = d(%{status: "grabbing", download_client_id: nil})
    downloading = d(%{status: "downloading"})

    assert get_download_status([grabbing, downloading]) == downloading
  end

  test "returns grabbing when nothing is active" do
    grabbing = d(%{status: "grabbing", download_client_id: nil})

    assert get_download_status([d(%{status: "imported"}), grabbing]) == grabbing
  end

  test "returns a failed grab when nothing is active or grabbing" do
    failed_grab = d(%{status: "failed", download_client_id: nil, error_message: "boom"})

    assert get_download_status([d(%{status: "imported"}), failed_grab]) == failed_grab
  end

  test "ignores failures that reached a client" do
    client_failure = d(%{status: "failed", download_client_id: "abc"})

    assert get_download_status([client_failure]) == nil
  end

  test "returns nil when nothing matches" do
    assert get_download_status([d(%{status: "imported"})]) == nil
  end
end
