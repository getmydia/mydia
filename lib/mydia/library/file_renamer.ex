defmodule Mydia.Library.FileRenamer do
  @moduledoc """
  Handles renaming media files to follow a consistent naming convention.

  Delegates to `FileNamer` for TRaSH Guides-compatible filename generation,
  building quality information from MediaFile database fields.
  """

  import Ecto.Query, warn: false

  alias Mydia.Library.Structs.Quality
  alias Mydia.Library.{FileNamer, MediaFile}
  alias Mydia.Media.MediaItem
  alias Mydia.Repo

  require Logger

  @doc """
  Generates a proposed filename for a media file based on its metadata.

  Returns a map with:
  - `:current_path` - The current full path
  - `:proposed_path` - The proposed full path
  - `:current_filename` - Just the current filename
  - `:proposed_filename` - Just the proposed filename
  - `:directory` - The directory path
  - `:extension` - The file extension
  """
  def generate_rename_preview(%MediaFile{} = file) do
    # Load associations if needed - force reload to ensure we have fresh data
    file = Repo.preload(file, [:library_path, :media_item, episode: :media_item], force: true)

    # Get the file details - use absolute_path for filesystem operations
    current_path = MediaFile.absolute_path(file)
    directory = Path.dirname(current_path)
    current_filename = Path.basename(current_path)

    # Generate proposed filename based on media type
    proposed_filename =
      cond do
        # TV Show Episode (associated with episode)
        file.episode_id && file.episode ->
          media_item = file.episode.media_item
          quality_info = build_quality_info(file)

          FileNamer.generate_episode_filename(
            media_item,
            file.episode,
            quality_info,
            current_filename
          )

        # Movie
        file.media_item_id && file.media_item && file.media_item.type == "movie" ->
          quality_info = build_quality_info(file)

          FileNamer.generate_movie_filename(
            file.media_item,
            quality_info,
            current_filename
          )

        # TV Show file not associated with episode (parse from filename)
        file.media_item_id && file.media_item && file.media_item.type == "tv_show" ->
          generate_filename_from_path(file)

        # Fallback to current filename if we can't determine
        true ->
          current_filename
      end

    proposed_path = Path.join(directory, proposed_filename)

    %{
      current_path: current_path,
      proposed_path: proposed_path,
      current_filename: current_filename,
      proposed_filename: proposed_filename,
      directory: directory,
      extension: Path.extname(current_path),
      file_id: file.id
    }
  end

  @doc """
  Generates rename previews for all files associated with a media item.

  Returns a list of preview maps.
  """
  def generate_rename_previews_for_media_item(%MediaItem{} = media_item) do
    active_files_query = from(mf in MediaFile, where: is_nil(mf.trashed_at))

    media_item =
      Repo.preload(media_item,
        media_files: active_files_query,
        episodes: [media_files: active_files_query]
      )

    # Get all media file IDs (both movie files and episode files)
    file_ids =
      if media_item.type == "tv_show" do
        # For TV shows, get all episode file IDs
        media_item.episodes
        |> Enum.flat_map(& &1.media_files)
        |> Enum.map(& &1.id)
      else
        # For movies, get media item file IDs
        media_item.media_files
        |> Enum.map(& &1.id)
      end

    # Reload each file fresh from database to ensure we have current data
    file_ids
    |> Enum.map(&Mydia.Library.get_media_file!/1)
    |> Enum.map(&generate_rename_preview/1)
  end

  @doc """
  Renames a media file on the filesystem and updates the database.

  Returns `{:ok, updated_file}` on success, or `{:error, reason}` on failure.
  """
  def rename_file(%MediaFile{} = file, new_path) when is_binary(new_path) do
    # Preload library_path to resolve absolute path
    file = Repo.preload(file, :library_path)
    current_path = MediaFile.absolute_path(file)

    cond do
      # Check if file exists
      not File.exists?(current_path) ->
        {:error, :file_not_found}

      # Check if target already exists
      File.exists?(new_path) and new_path != current_path ->
        {:error, :target_exists}

      # Check if paths are the same (nothing to do)
      current_path == new_path ->
        {:ok, file}

      # Perform the rename
      true ->
        # Ensure target directory exists
        target_dir = Path.dirname(new_path)
        File.mkdir_p!(target_dir)

        case File.rename(current_path, new_path) do
          :ok ->
            # Calculate the new relative path
            library_path_root = file.library_path.path
            new_relative_path = Path.relative_to(new_path, library_path_root)

            # Update the database with the new relative path
            case Mydia.Library.update_media_file(file, %{relative_path: new_relative_path}) do
              {:ok, updated_file} ->
                Logger.info("Successfully renamed file",
                  file_id: file.id,
                  old_path: current_path,
                  new_path: new_path,
                  new_relative_path: new_relative_path
                )

                {:ok, updated_file}

              {:error, changeset} ->
                # Rollback: rename file back
                File.rename(new_path, current_path)

                Logger.error("Failed to update database after rename, rolled back",
                  file_id: file.id,
                  errors: inspect(changeset.errors)
                )

                {:error, :database_update_failed}
            end

          {:error, reason} ->
            Logger.error("Failed to rename file",
              file_id: file.id,
              reason: inspect(reason)
            )

            {:error, reason}
        end
    end
  end

  @doc """
  Renames multiple media files in a batch operation.

  Accepts a list of maps with `:file_id` and `:new_path` keys.

  Returns `{:ok, results}` where results is a list of `{:ok, file}` or `{:error, reason}` tuples.
  """
  def rename_files_batch(rename_specs) when is_list(rename_specs) do
    results =
      Enum.map(rename_specs, fn %{file_id: file_id, new_path: new_path} ->
        file = Mydia.Library.get_media_file!(file_id)
        rename_file(file, new_path)
      end)

    success_count = Enum.count(results, &match?({:ok, _}, &1))
    error_count = Enum.count(results, &match?({:error, _}, &1))

    Logger.info("Batch rename completed",
      total: length(results),
      success: success_count,
      errors: error_count
    )

    {:ok, results}
  end

  @doc """
  Builds a `Quality` struct from a MediaFile's database fields.

  Uses resolution, codec, audio_codec, and hdr_format from the MediaFile,
  plus source from the file's metadata. This is the authoritative quality
  source for files already in the library (vs parsing from filename).
  """
  def build_quality_info(%MediaFile{} = file) do
    source =
      if file.metadata && file.metadata.source do
        file.metadata.source
      else
        nil
      end

    Quality.new(%{
      resolution: file.resolution,
      source: source,
      codec: file.codec,
      audio: file.audio_codec,
      hdr_format: file.hdr_format,
      dolby_vision: not is_nil(file.dolby_vision_profile),
      proper: false,
      repack: false
    })
  end

  ## Private Functions

  defp generate_filename_from_path(%MediaFile{} = file) do
    # For TV show files not associated with episodes, parse the filename
    # to extract season/episode info and generate a TRaSH-style name
    absolute_path = MediaFile.absolute_path(file)
    current_filename = Path.basename(absolute_path)
    extension = Path.extname(absolute_path)
    basename = Path.basename(absolute_path, extension)
    media_item = file.media_item

    # Try to extract S##E## or similar pattern from filename
    case Regex.run(~r/[Ss](\d+)[Ee](\d+)/, basename) do
      [_, season_str, episode_str] ->
        # Build a minimal episode-like map for FileNamer
        episode_title =
          case Regex.run(~r/[Ee]\d+[.\s]+([^.\d]+?)(?:\d{3,4}p|\.mkv|\.mp4)/i, basename) do
            [_, title] ->
              title
              |> String.replace([".", "_"], " ")
              |> String.trim()

            _ ->
              "Episode #{String.pad_leading(episode_str, 2, "0")}"
          end

        pseudo_episode = %{
          season_number: String.to_integer(season_str),
          episode_number: String.to_integer(episode_str),
          title: episode_title
        }

        quality_info = build_quality_info(file)

        FileNamer.generate_episode_filename(
          media_item,
          pseudo_episode,
          quality_info,
          current_filename
        )

      _ ->
        # Can't parse, keep original filename
        current_filename
    end
  end
end
