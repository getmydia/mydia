defmodule Mydia.DownloadsFixtures do
  @moduledoc """
  This module defines test helpers for creating entities via the `Mydia.Downloads` context.
  """

  import Mydia.MediaFixtures

  @doc """
  Generate a download.
  """
  def download_fixture(attrs \\ %{}) do
    # Convert keyword list to map if needed
    attrs = Map.new(attrs)

    # Create a media item if not provided
    media_item_id =
      case Map.get(attrs, :media_item_id) do
        nil ->
          media_item = media_item_fixture()
          media_item.id

        id ->
          id
      end

    {:ok, download} =
      attrs
      |> Enum.into(%{
        media_item_id: media_item_id,
        title: "Test Download #{System.unique_integer([:positive])}",
        status: "pending",
        indexer: "test-indexer",
        release_name: "Test.Release.1080p.WEB-DL",
        size_bytes: 1_000_000_000,
        progress: 0
      })
      |> Mydia.Downloads.create_download()

    download
  end
end
