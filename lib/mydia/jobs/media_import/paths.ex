defmodule Mydia.Jobs.MediaImport.Paths do
  @moduledoc false

  require Logger
  alias Mydia.Settings
  alias Mydia.Library.{FileNamer, FileOrganizer}
  alias Mydia.Library.ItemFolders.Home
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
    item = download.media_item

    if item && (item.type in ["movie", "tv_show"] || download.episode) do
      item_destination_dir(item, download.episode, library_path,
        prefer_file_id: upgrade_target_id(download)
      )
    else
      # Unknown - use download title
      Path.join(library_path.path, sanitize_filename(download.title))
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

  @doc """
  Where `media_item`'s file (for `episode`, when given) goes in `library_path`:
  the folder the item already uses there, else the generated one. A movie
  ignores `episode`.
  """
  def item_destination_dir(media_item, episode, library_path, opts \\ [])

  def item_destination_dir(%{type: "movie"} = media_item, _episode, library_path, opts) do
    existing_or(media_item, library_path, opts, fn ->
      generated_movie_dir(media_item, library_path)
    end)
  end

  def item_destination_dir(media_item, nil, library_path, _opts),
    do: build_series_base_path(media_item, library_path)

  def item_destination_dir(media_item, episode, library_path, _opts) do
    base = build_series_base_path(media_item, library_path, episode)
    season_dir(base, media_item, library_path, episode.season_number)
  end

  # Helper to build the base path for TV series: the folder the show already
  # uses, else the category-aware generated one.
  @doc false
  def build_series_base_path(media_item, library_path),
    do: series_base(media_item, library_path, [])

  # With the episode being placed, the folder already holding that episode's
  # file wins when the show is split across trusted folders.
  @doc false
  def build_series_base_path(media_item, library_path, episode) do
    series_base(media_item, library_path, prefer_episode_id: episode && episode.id)
  end

  defp series_base(media_item, library_path, prefer) do
    existing_or(media_item, library_path, prefer, fn ->
      if library_path.auto_organize do
        FileOrganizer.destination_path(media_item, library_path)
      else
        Path.join(library_path.path, sanitize_filename(media_item.title))
      end
    end)
  end

  @doc """
  The season folder under a show folder: the one the show already uses for
  this season, else `Season NN`.
  """
  def season_dir(base, media_item, library_path, season) do
    name =
      Home.season_folder_name(media_item, library_path, base, season) ||
        "Season #{String.pad_leading("#{season}", 2, "0")}"

    Path.join(base, name)
  end

  # An item already living in a folder keeps getting its files there
  # (getmydia/mydia#1237). Relocating it into a category path is the explicit
  # reorganize action's job, not an import's.
  defp existing_or(media_item, library_path, prefer, generate) do
    case Home.find(media_item, library_path, prefer) do
      {:ok, folder} -> folder.absolute
      :none -> generate.()
    end
  end

  defp generated_movie_dir(media_item, library_path) do
    if library_path.auto_organize do
      FileOrganizer.destination_path(media_item, library_path)
    else
      title = sanitize_filename(media_item.title)

      if media_item.year,
        do: Path.join(library_path.path, "#{title} (#{media_item.year})"),
        else: Path.join(library_path.path, title)
    end
  end

  defp upgrade_target_id(%{metadata: %{"upgrade_target_media_file_id" => id}}) when is_binary(id),
    do: id

  defp upgrade_target_id(_download), do: nil

  defp sanitize_filename(filename) do
    filename
    |> String.replace(~r/[<>:"|?*]/, "")
    |> String.replace(~r/[\/\\]/, "-")
    |> String.trim()
  end

  @doc false
  def generate_filename(download, episode, original_filename, rename_files?)
      when is_boolean(rename_files?) do
    item_filename(download.media_item, episode, original_filename, rename_files?, download.title)
  end

  @doc """
  The file name for `original_filename` in a library with renaming set to
  `rename?`. Quality is parsed from `quality_source`, else the original name.
  """
  def item_filename(_media_item, _episode, original_filename, false, _quality_source),
    do: original_filename

  def item_filename(media_item, episode, original_filename, true, quality_source) do
    quality_info = QualityParser.parse(quality_source || original_filename)

    cond do
      media_item.type == "tv_show" && not is_nil(episode) ->
        FileNamer.generate_episode_filename(media_item, episode, quality_info, original_filename)

      media_item.type == "movie" ->
        FileNamer.generate_movie_filename(media_item, quality_info, original_filename)

      true ->
        original_filename
    end
  end
end
