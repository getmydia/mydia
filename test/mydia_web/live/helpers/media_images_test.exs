defmodule MydiaWeb.Live.Helpers.MediaImagesTest do
  @moduledoc """
  `poster_url/2`'s populated branch had no coverage on this branch: every rail
  test builds `metadata: nil`, so only the placeholder path was ever exercised.
  This covers the populated path (including that the `size` argument is
  actually threaded through to `ImageUrl.poster_url/2`, not silently dropped)
  alongside the two placeholder cases.
  """

  use ExUnit.Case, async: true

  alias Mydia.Metadata.Structs.MediaMetadata
  alias MydiaWeb.Live.Helpers.MediaImages

  @placeholder "/images/no-poster.svg"

  defp media_item(metadata), do: %{metadata: metadata}

  defp metadata(attrs) do
    struct(
      MediaMetadata,
      Enum.into(attrs, %{provider_id: "101", provider: :tmdb, media_type: :movie})
    )
  end

  test "returns a poster URL built from the metadata's poster_path" do
    item = media_item(metadata(%{poster_path: "/abc123.jpg"}))

    url = MediaImages.poster_url(item)

    assert url != @placeholder
    assert url =~ "/abc123.jpg"
    assert url =~ "/w500/"
  end

  test "threads an explicit size through instead of ignoring it" do
    item = media_item(metadata(%{poster_path: "/abc123.jpg"}))

    default_size_url = MediaImages.poster_url(item)
    narrow_url = MediaImages.poster_url(item, "w342")

    assert narrow_url != default_size_url
    assert narrow_url =~ "/w342/"
  end

  test "returns the placeholder when the media item has no metadata" do
    item = media_item(nil)

    assert MediaImages.poster_url(item) == @placeholder
  end

  test "returns the placeholder when metadata has no poster_path" do
    item = media_item(metadata(%{poster_path: nil}))

    assert MediaImages.poster_url(item) == @placeholder
  end

  test "returns the placeholder when poster_path is an empty string" do
    item = media_item(metadata(%{poster_path: ""}))

    assert MediaImages.poster_url(item) == @placeholder
  end
end
