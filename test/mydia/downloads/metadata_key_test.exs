defmodule Mydia.Downloads.MetadataKeyTest do
  use Mydia.DataCase, async: true

  import Mydia.DownloadsFixtures

  alias Mydia.Downloads
  alias Mydia.Downloads.MetadataKey

  test "put/3 merges without dropping other keys" do
    download = download_fixture(%{metadata: %{"tracker_terms" => %{"private" => true}}})

    assert :ok = MetadataKey.put(download.id, "seeding_goal_reached_at", "2031-01-01T00:00:00Z")

    metadata = Downloads.get_download!(download.id).metadata
    assert metadata["tracker_terms"] == %{"private" => true}
    assert metadata["seeding_goal_reached_at"] == "2031-01-01T00:00:00Z"
  end

  test "put/3 is :ok for a missing row" do
    assert :ok = MetadataKey.put(Ecto.UUID.generate(), "k", "v")
  end

  test "modify/2 applies the function to the stored metadata" do
    download = download_fixture(%{metadata: %{"file_selection" => %{"source" => "manual"}}})

    assert :ok =
             MetadataKey.modify(download.id, fn metadata ->
               Map.update(metadata, "early_imported_paths", ["a.mkv"], &(&1 ++ ["a.mkv"]))
             end)

    metadata = Downloads.get_download!(download.id).metadata
    assert metadata["file_selection"] == %{"source" => "manual"}
    assert metadata["early_imported_paths"] == ["a.mkv"]
  end

  test "modify/2 is :ok for a missing row" do
    assert :ok = MetadataKey.modify(Ecto.UUID.generate(), &Map.put(&1, "k", "v"))
  end
end
