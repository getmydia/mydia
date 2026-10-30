defmodule MydiaWeb.MediaLive.Show.HelpersStatusTest do
  use ExUnit.Case, async: true

  import MydiaWeb.MediaLive.Show.Helpers, only: [get_grab_status: 1]

  defp d(attrs) do
    Map.merge(
      %{status: "missing", download_client_id: "abc", error_message: nil, title: "t"},
      attrs
    )
  end

  test "prefers a grab in flight over a failed grab" do
    grabbing = d(%{status: "grabbing", download_client_id: nil})
    failed_grab = d(%{status: "failed", download_client_id: nil})

    assert get_grab_status([failed_grab, grabbing]) == grabbing
  end

  test "returns a failed grab when nothing is grabbing" do
    failed_grab = d(%{status: "failed", download_client_id: nil, error_message: "boom"})

    assert get_grab_status([d(%{status: "imported"}), failed_grab]) == failed_grab
  end

  test "ignores failures that reached a client" do
    client_failure = d(%{status: "failed", download_client_id: "abc"})

    assert get_grab_status([client_failure]) == nil
  end

  test "ignores in-client downloads, which DownloadSummary owns" do
    assert get_grab_status([d(%{status: "downloading"}), d(%{status: "seeding"})]) == nil
  end
end
