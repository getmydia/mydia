defmodule Mydia.Jobs.MediaImport.Paths do
  @moduledoc false

  require Logger
  alias Mydia.Settings
  alias Mydia.Library.{FileNamer, FileOrganizer}
  alias Mydia.Library.TargetResolver
  alias Mydia.Indexers.QualityParser
  alias Mydia.Settings.LibraryPath

  @doc false
  def determine_library_path(download) do
    cond do
      download.library_path ->
        download.library_path

      is_nil(download.media_item) ->
        # A download with no media item has no kind to resolve against. This
        # branch preserves the historical :mixed-only lookup verbatim; nothing
        # in the targeting design changes what should happen to an
        # unattributed download.
        resolve_unattributed(download)

      true ->
        case TargetResolver.resolve(download.media_item, download: download) do
          {:ok, library_path, _reason} ->
            library_path

          {:error, :no_compatible_library} ->
            warn_no_library(download, download.media_item.type)
            nil
        end
    end
  end

  defp resolve_unattributed(download) do
    library_paths = Settings.list_library_paths()

    library_path =
      Enum.find(library_paths, &(&1.type == :mixed and &1.monitored))

    if is_nil(library_path), do: warn_no_library(download, "unknown")

    library_path
  end

  defp warn_no_library(download, media_type) do
    Logger.warning("No compatible library path found for import",
      download_id: download.id,
      media_type: media_type,
      available_libraries:
        Enum.map(Settings.list_library_paths(), fn lp ->
          %{path: lp.path, type: lp.type, monitored: lp.monitored}
        end)
    )
  end

  @doc false
  def build_destination_path(download, library_path) when is_struct(library_path, LibraryPath) do
    # Use FileOrganizer for category-aware destination paths when auto_organize is enabled
    cond do
      # Movie with auto_organize enabled
      download.media_item && download.media_item.type == "movie" && library_path.auto_organize ->
        FileOrganizer.destination_path(download.media_item, library_path)

      # TV episode - always use show folder + season subfolder
      download.episode && download.media_item ->
        # Get base folder (potentially category-aware)
        base_folder =
          if library_path.auto_organize do
            FileOrganizer.destination_path(download.media_item, library_path)
          else
            title = sanitize_filename(download.media_item.title)
            Path.join(library_path.path, title)
          end

        season = download.episode.season_number
        Path.join(base_folder, "Season #{String.pad_leading("#{season}", 2, "0")}")

      # Movie without auto_organize
      download.media_item && download.media_item.type == "movie" ->
        title = sanitize_filename(download.media_item.title)
        year = download.media_item.year

        if year do
          Path.join([library_path.path, "#{title} (#{year})"])
        else
          Path.join([library_path.path, title])
        end

      # TV show (no specific episode) - use category-aware path if enabled
      download.media_item && download.media_item.type == "tv_show" ->
        if library_path.auto_organize do
          FileOrganizer.destination_path(download.media_item, library_path)
        else
          title = sanitize_filename(download.media_item.title)
          Path.join(library_path.path, title)
        end

      # Unknown - use download title
      true ->
        title = sanitize_filename(download.title)
        Path.join(library_path.path, title)
    end
  end

  # Legacy clause for string library_root (used internally)
  def build_destination_path(download, library_root) when is_binary(library_root) do
    cond do
      # TV episode
      download.episode && download.media_item ->
        title = sanitize_filename(download.media_item.title)
        season = download.episode.season_number

        Path.join([library_root, title, "Season #{String.pad_leading("#{season}", 2, "0")}"])

      # Movie
      download.media_item && download.media_item.type == "movie" ->
        title = sanitize_filename(download.media_item.title)
        year = download.media_item.year

        if year do
          Path.join([library_root, "#{title} (#{year})"])
        else
          Path.join([library_root, title])
        end

      # TV show (no specific episode) - fallback
      download.media_item && download.media_item.type == "tv_show" ->
        title = sanitize_filename(download.media_item.title)
        Path.join([library_root, title])

      # Unknown - use download title
      true ->
        title = sanitize_filename(download.title)
        Path.join([library_root, title])
    end
  end

  # Helper to build category-aware base path for TV series
  @doc false
  def build_series_base_path(media_item, library_path) do
    if library_path.auto_organize do
      FileOrganizer.destination_path(media_item, library_path)
    else
      title = sanitize_filename(media_item.title)
      Path.join(library_path.path, title)
    end
  end

  defp sanitize_filename(filename) do
    filename
    |> String.replace(~r/[<>:"|?*]/, "")
    |> String.replace(~r/[\/\\]/, "-")
    |> String.trim()
  end

  @doc false
  def generate_filename(download, episode, original_filename, rename_files?)
      when is_boolean(rename_files?) do
    # Only rename if explicitly enabled (default: false for safety)
    if rename_files? do
      # Parse quality information from download title or original filename
      quality_info =
        QualityParser.parse(download.title || original_filename)

      media_item = download.media_item

      cond do
        # TV episode with episode info
        media_item.type == "tv_show" && not is_nil(episode) ->
          FileNamer.generate_episode_filename(
            media_item,
            episode,
            quality_info,
            original_filename
          )

        # Movie
        media_item.type == "movie" ->
          FileNamer.generate_movie_filename(
            media_item,
            quality_info,
            original_filename
          )

        # Fallback to original filename
        true ->
          original_filename
      end
    else
      # Renaming disabled - use original filename
      original_filename
    end
  end
end
