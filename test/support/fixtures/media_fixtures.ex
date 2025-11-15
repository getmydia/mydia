defmodule Mydia.MediaFixtures do
  @moduledoc """
  This module defines test helpers for creating entities via the `Mydia.Media` context.
  """

  import Mydia.SettingsFixtures

  @doc """
  Generate a media item.
  """
  def media_item_fixture(attrs \\ %{}) do
    {:ok, media_item} =
      attrs
      |> Enum.into(%{
        type: "movie",
        title: "Test Movie #{System.unique_integer([:positive])}",
        year: 2024,
        monitored: true
      })
      |> Mydia.Media.create_media_item()

    media_item
  end

  @doc """
  Generate an episode.
  """
  def episode_fixture(attrs \\ %{}) do
    # Convert keyword list to map if needed
    attrs = Map.new(attrs)

    # Create a media item if not provided
    media_item_id =
      case Map.get(attrs, :media_item_id) do
        nil ->
          media_item = media_item_fixture(%{type: "tv_show"})
          media_item.id

        id ->
          id
      end

    {:ok, episode} =
      attrs
      |> Enum.into(%{
        media_item_id: media_item_id,
        season_number: 1,
        episode_number: System.unique_integer([:positive]),
        title: "Test Episode",
        monitored: true
      })
      |> Mydia.Media.create_episode()

    episode
  end

  @doc """
  Generate a media file.
  """
  def media_file_fixture(attrs \\ %{}) do
    # Convert keyword list to map if needed
    attrs = Map.new(attrs)

    # Create library_path if not provided
    attrs =
      if Map.has_key?(attrs, :library_path_id) do
        attrs
      else
        # Determine library type based on media_item or episode
        library_type =
          cond do
            Map.has_key?(attrs, :episode_id) -> "series"
            true -> "movies"
          end

        library_path = library_path_fixture(%{type: library_type})
        Map.put(attrs, :library_path_id, library_path.id)
      end

    # Ensure either media_item_id or episode_id is provided
    attrs =
      cond do
        Map.has_key?(attrs, :media_item_id) or Map.has_key?(attrs, :episode_id) ->
          attrs

        true ->
          # Create a movie by default
          media_item = media_item_fixture(%{type: "movie"})
          Map.put(attrs, :media_item_id, media_item.id)
      end

    # Get library_path to construct full path (for backward compatibility during migration)
    library_path = Mydia.Repo.get!(Mydia.Settings.LibraryPath, attrs.library_path_id)

    # Build default attrs
    default_attrs = %{
      relative_path: "test/file-#{System.unique_integer([:positive])}.mp4",
      size: 1_000_000_000,
      resolution: "1080p",
      codec: "h264",
      audio_codec: "aac",
      metadata: %{"container" => "mp4"}
    }

    # Merge attrs with defaults
    final_attrs = Enum.into(attrs, default_attrs)

    # Add full path for backward compatibility (using relative_path from final_attrs)
    final_attrs =
      Map.put(final_attrs, :path, Path.join(library_path.path, final_attrs.relative_path))

    {:ok, media_file} = Mydia.Library.create_media_file(final_attrs)

    media_file
  end
end
