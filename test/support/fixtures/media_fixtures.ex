defmodule Mydia.MediaFixtures do
  @moduledoc """
  This module defines test helpers for creating entities via the `Mydia.Media` context.
  """

  import Ecto.Query
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
      #
      # Merging below (Enum.into(attrs, default_attrs)) replaces :metadata
      # wholesale rather than deep-merging it: a caller that passes its own
      # `metadata:` overrides this entire map, including the "duration" key,
      # not just the keys it sets. Any override MUST include "duration" (or
      # set analyzed_at: nil) or that row will still ffprobe.
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

  @doc """
  Rewrites a media file's `inserted_at`.

  `Mydia.Library.create_media_file/1` cannot set it (timestamps are not cast),
  so any test that needs a file to look old has to go around the changeset.
  """
  def backdate_media_file(%Mydia.Library.MediaFile{} = media_file, %DateTime{} = at) do
    at = DateTime.truncate(at, :second)

    {1, _} =
      Mydia.Repo.update_all(
        from(f in Mydia.Library.MediaFile, where: f.id == ^media_file.id),
        set: [inserted_at: at]
      )

    %{media_file | inserted_at: at}
  end

  @doc """
  Creates a media file with no parent association.

  `media_file_fixture/1` cannot do this. It goes through
  `Library.create_media_file/1`, and that changeset requires a media_item or an
  episode on any non-specialized library. Orphans are a first-class state in
  this app (the scanner creates them constantly) but they are only reachable
  through `create_scanned_media_file/1`, which uses `scan_changeset`.
  """
  def orphaned_media_file_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)

    attrs =
      if Map.has_key?(attrs, :library_path_id) do
        attrs
      else
        Map.put(attrs, :library_path_id, library_path_fixture().id)
      end

    defaults = %{
      relative_path: "orphan/file-#{System.unique_integer([:positive])}.mkv",
      size: 1_000_000_000,
      verified_at: DateTime.utc_now()
    }

    {:ok, media_file} =
      defaults
      |> Map.merge(attrs)
      |> Mydia.Library.create_scanned_media_file()

    media_file
  end

  @doc "Generate a durable import candidate."
  def import_candidate_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)

    library_path_id = Map.get_lazy(attrs, :library_path_id, fn -> library_path_fixture().id end)

    relative_path =
      Map.get(attrs, :relative_path, "candidate/file-#{System.unique_integer([:positive])}.mkv")

    library_path = Mydia.Settings.get_library_path!(library_path_id)

    anchor =
      Mydia.Library.PathAnchor.anchor_for(
        Path.join(library_path.path, relative_path),
        library_path.path
      )

    {:ok, candidate} =
      Mydia.ImportCandidates.upsert(
        Map.merge(
          %{
            library_path_id: library_path_id,
            relative_path: relative_path,
            anchor_key: anchor.cluster_key,
            size: 1_000_000_000,
            discovered_at: DateTime.utc_now() |> DateTime.truncate(:second)
          },
          attrs
        )
      )

    candidate
  end
end
