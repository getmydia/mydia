defmodule Mydia.MediaFixtures do
  @moduledoc """
  This module defines test helpers for creating entities via the `Mydia.Media` context.
  """

  import Mydia.SettingsFixtures

  @doc """
  Generate a media item.

  By default, skips automatic episode refresh for TV shows in tests
  to avoid external API calls and allow tests to create their own episodes.
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
      # Skip episode refresh in tests to avoid external API calls
      # and to allow tests to create their own episode fixtures
      |> Mydia.Media.create_media_item(skip_episode_refresh: true)

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
          if Map.has_key?(attrs, :episode_id) do
            "series"
          else
            "movies"
          end

        library_path = library_path_fixture(%{type: library_type})
        Map.put(attrs, :library_path_id, library_path.id)
      end

    # Ensure either media_item_id or episode_id is provided
    attrs =
      if Map.has_key?(attrs, :media_item_id) or Map.has_key?(attrs, :episode_id) do
        attrs
      else
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
      # Default to an already-analyzed row so no test accidentally shells out
      # to ffprobe. Candidates.ensure_codec_info/1 only short-circuits when
      # analyzed_at is set AND metadata carries a duration: with analyzed_at
      # alone it falls to the second clause (candidates.ex:197), which calls
      # ThumbnailGenerator.get_duration/1 and shells out anyway. Tests that
      # exercise analysis pass analyzed_at: nil explicitly.
      analyzed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      metadata: %{"container" => "mp4", "duration" => 120.5}
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
