defmodule Mydia.Metadata.NfoWriter do
  @moduledoc """
  Generates and writes Jellyfin-compatible NFO metadata files alongside media files.

  NFO files are XML files that Jellyfin, Kodi, and Emby can read to display metadata
  without needing to scrape external sources.

  This module is pure (no process state) and handles:
  - XML generation for movies, TV shows, seasons, and episodes
  - Atomic file writing (write to .tmp, then rename)
  - Show root and season folder detection from media file paths
  """

  require Logger

  alias Mydia.Accounts.Scope
  alias Mydia.Library.MediaFile
  alias Mydia.Media
  alias Mydia.Media.MediaItem
  alias Mydia.Metadata.Structs.MediaMetadata
  alias Mydia.Settings.LibraryPath
  alias Mydia.Library.PathParser

  @doc """
  Writes NFO files for a media item across all library paths with `write_nfo` enabled.

  Accepts either a pre-loaded `%MediaItem{}` struct or a media item ID string.
  When a struct is passed, it will be preloaded if needed (avoiding redundant DB loads
  when callers already have the data). When an ID is passed, the full item is loaded.

  Always returns `:ok` - failures are logged as warnings.
  """
  @spec maybe_write_nfos(MediaItem.t() | binary()) :: :ok
  def maybe_write_nfos(%MediaItem{} = media_item) do
    media_item = Mydia.Repo.preload(media_item, [:episodes, media_files: :library_path])
    do_write_nfos(media_item)
  rescue
    e ->
      Logger.warning("NFO export failed: #{Exception.message(e)}")
      :ok
  end

  def maybe_write_nfos(media_item_id) when is_binary(media_item_id) do
    media_item =
      Media.get_media_item!(Scope.system(), media_item_id,
        preload: [:episodes, media_files: :library_path]
      )

    do_write_nfos(media_item)
  rescue
    e ->
      Logger.warning("NFO export failed: #{Exception.message(e)}")
      :ok
  end

  defp do_write_nfos(media_item) do
    if is_nil(media_item.metadata) do
      :ok
    else
      library_paths =
        media_item.media_files
        |> Enum.filter(&(not is_nil(&1.library_path) and is_nil(&1.trashed_at)))
        |> Enum.map(& &1.library_path)
        |> Enum.uniq_by(& &1.id)
        |> Enum.filter(& &1.write_nfo)

      Enum.each(library_paths, fn library_path ->
        write_for_media_item(media_item, library_path)
      end)
    end
  end

  @doc """
  Deletes the NFO file associated with a media file, if it exists.
  """
  @spec delete_nfo_for_file(String.t()) :: :ok
  def delete_nfo_for_file(absolute_path) when is_binary(absolute_path) do
    nfo_path = Path.rootname(absolute_path) <> ".nfo"

    if File.exists?(nfo_path) do
      case File.rm(nfo_path) do
        :ok ->
          Logger.info("Deleted NFO file", path: nfo_path)
          :ok

        {:error, reason} ->
          Logger.warning("Failed to delete NFO file #{nfo_path}: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  @doc """
  Writes NFO files for a media item and all its associated files in a given library path.

  For movies: writes `<filename>.nfo` next to each video file.
  For TV shows: writes `tvshow.nfo`, `season.nfo` (if season folders exist),
  and `<filename>.nfo` for each episode file.

  Returns `:ok` regardless of individual file write failures (failures are logged).
  """
  @spec write_for_media_item(MediaItem.t(), LibraryPath.t()) :: :ok
  def write_for_media_item(%MediaItem{metadata: nil}, _library_path), do: :ok

  def write_for_media_item(%MediaItem{} = media_item, %LibraryPath{} = library_path) do
    media_files = get_active_media_files(media_item, library_path)

    if media_files == [] do
      :ok
    else
      case media_item.type do
        "movie" -> write_movie_nfos(media_item, media_files, library_path)
        "tv_show" -> write_tv_show_nfos(media_item, media_files, library_path)
        _other -> :ok
      end
    end
  end

  defp write_movie_nfos(%MediaItem{} = media_item, media_files, _library_path) do
    xml = generate_movie_xml(media_item)

    Enum.each(media_files, fn media_file ->
      case MediaFile.absolute_path(media_file) do
        nil ->
          :ok

        abs_path ->
          nfo_path = Path.rootname(abs_path) <> ".nfo"
          write_nfo_file(nfo_path, xml)
      end
    end)
  end

  defp write_tv_show_nfos(%MediaItem{} = media_item, media_files, %LibraryPath{} = library_path) do
    # Write tvshow.nfo in the show root directory
    case derive_show_root(media_files, library_path) do
      nil ->
        :ok

      show_root ->
        tvshow_xml = generate_tvshow_xml(media_item)
        write_nfo_file(Path.join(show_root, "tvshow.nfo"), tvshow_xml)
    end

    # Write season.nfo files for detected season folders
    season_folders = detect_season_folders(media_files, library_path)

    Enum.each(season_folders, fn {season_number, season_path} ->
      season_xml = generate_season_xml(media_item, season_number)
      write_nfo_file(Path.join(season_path, "season.nfo"), season_xml)
    end)

    # Write episode NFOs
    write_episode_nfos(media_item, media_files)
  end

  defp write_episode_nfos(%MediaItem{} = media_item, media_files) do
    # Build a lookup of episodes by ID for quick access
    episodes_by_id =
      case media_item.episodes do
        %Ecto.Association.NotLoaded{} -> %{}
        episodes -> Map.new(episodes, &{&1.id, &1})
      end

    Enum.each(media_files, fn media_file ->
      episode = get_episode(media_file, episodes_by_id)

      if episode do
        case MediaFile.absolute_path(media_file) do
          nil ->
            :ok

          abs_path ->
            xml = generate_episode_xml(media_item, episode)
            nfo_path = Path.rootname(abs_path) <> ".nfo"
            write_nfo_file(nfo_path, xml)
        end
      end
    end)
  end

  # XML Generation

  @doc """
  Generates movie NFO XML content.
  """
  @spec generate_movie_xml(MediaItem.t()) :: String.t()
  def generate_movie_xml(%MediaItem{metadata: nil} = media_item) do
    build_xml("movie", [
      xml_element("title", media_item.title)
    ])
  end

  def generate_movie_xml(%MediaItem{metadata: %MediaMetadata{} = meta} = media_item) do
    directors =
      (meta.crew || [])
      |> Enum.filter(&(&1.job == "Director"))
      |> Enum.map(& &1.name)

    build_xml("movie", [
      xml_element("title", meta.title || media_item.title),
      xml_element("originaltitle", meta.original_title),
      xml_element("sorttitle", meta.title || media_item.title),
      xml_element("year", meta.year),
      xml_element("rating", meta.vote_average),
      xml_element("plot", meta.overview),
      xml_element("tagline", meta.tagline),
      xml_element("runtime", meta.runtime),
      xml_repeated("genre", meta.genres || []),
      xml_uniqueids(media_item, meta),
      xml_cast(meta.cast || []),
      xml_repeated("director", directors)
    ])
  end

  @doc """
  Generates TV show NFO XML content.
  """
  @spec generate_tvshow_xml(MediaItem.t()) :: String.t()
  def generate_tvshow_xml(%MediaItem{metadata: nil} = media_item) do
    build_xml("tvshow", [
      xml_element("title", media_item.title)
    ])
  end

  def generate_tvshow_xml(%MediaItem{metadata: %MediaMetadata{} = meta} = media_item) do
    build_xml("tvshow", [
      xml_element("title", meta.title || media_item.title),
      xml_element("originaltitle", meta.original_title),
      xml_element("year", meta.year),
      xml_element("rating", meta.vote_average),
      xml_element("plot", meta.overview),
      xml_repeated("genre", meta.genres || []),
      xml_element("status", meta.status),
      xml_uniqueids(media_item, meta),
      xml_cast(meta.cast || [])
    ])
  end

  @doc """
  Generates season NFO XML content.
  """
  @spec generate_season_xml(MediaItem.t(), integer()) :: String.t()
  def generate_season_xml(%MediaItem{} = media_item, season_number) do
    season_info = find_season_info(media_item, season_number)

    title =
      case season_info do
        %{name: name} when is_binary(name) and name != "" -> name
        _ -> "Season #{season_number}"
      end

    overview =
      case season_info do
        %{overview: overview} when is_binary(overview) -> overview
        _ -> nil
      end

    build_xml("season", [
      xml_element("title", title),
      xml_element("seasonnumber", season_number),
      xml_element("plot", overview)
    ])
  end

  @doc """
  Generates episode NFO XML content.
  """
  @spec generate_episode_xml(MediaItem.t(), Mydia.Media.Episode.t()) :: String.t()
  def generate_episode_xml(%MediaItem{} = media_item, episode) do
    ep_meta = episode.metadata

    {ep_title, ep_overview, ep_runtime, ep_aired} =
      case ep_meta do
        %{name: name, overview: overview, runtime: runtime, air_date: air_date} ->
          {name, overview, runtime, air_date}

        _ ->
          {episode.title, nil, nil, episode.air_date}
      end

    build_xml("episodedetails", [
      xml_element("title", ep_title || episode.title),
      xml_element("showtitle", media_item.title),
      xml_element("season", episode.season_number),
      xml_element("episode", episode.episode_number),
      xml_element("aired", format_date(ep_aired || episode.air_date)),
      xml_element("plot", ep_overview),
      xml_element("runtime", ep_runtime),
      xml_uniqueid("tmdb", media_item.tmdb_id)
    ])
  end

  # File Operations

  @doc """
  Writes content to an NFO file atomically (write to .tmp, then rename).

  Returns `:ok` on success, logs a warning on failure.
  """
  @spec write_nfo_file(String.t(), String.t()) :: :ok | {:error, term()}
  def write_nfo_file(path, content) do
    tmp_path = path <> ".tmp"

    with :ok <- File.write(tmp_path, content),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, reason} = error ->
        Logger.warning("Failed to write NFO file #{path}: #{inspect(reason)}")
        # Clean up tmp file if it exists
        File.rm(tmp_path)
        error
    end
  end

  @doc """
  Derives the show root directory from media files in a library path.

  Examines the relative paths of media files to find the common show directory.
  If files are in season folders, the show root is the parent of those folders.
  """
  @spec derive_show_root([MediaFile.t()], LibraryPath.t()) :: String.t() | nil
  def derive_show_root(media_files, %LibraryPath{} = library_path) do
    media_files
    |> Enum.find_value(fn media_file ->
      case media_file.relative_path do
        nil ->
          nil

        relative_path ->
          parts = Path.split(relative_path)
          # Find which part is the season folder (if any)
          show_parts = find_show_root_parts(parts)

          if show_parts != [] do
            Path.join([library_path.path | show_parts])
          else
            nil
          end
      end
    end)
  end

  @doc """
  Detects season folders from media file paths.

  Returns a list of `{season_number, absolute_season_folder_path}` tuples
  for each unique season folder found among the media files.
  """
  @spec detect_season_folders([MediaFile.t()], LibraryPath.t()) :: [{integer(), String.t()}]
  def detect_season_folders(media_files, %LibraryPath{} = library_path) do
    media_files
    |> Enum.flat_map(fn media_file ->
      case media_file.relative_path do
        nil ->
          []

        relative_path ->
          parts = Path.split(relative_path)
          find_season_folder_info(parts, library_path.path)
      end
    end)
    |> Enum.uniq_by(fn {season_number, _path} -> season_number end)
  end

  @doc """
  Counts the number of NFO files that would be written for a media item in a library path.
  """
  @spec count_nfo_files(MediaItem.t(), LibraryPath.t()) :: non_neg_integer()
  def count_nfo_files(%MediaItem{} = media_item, %LibraryPath{} = library_path) do
    files = get_active_media_files(media_item, library_path)

    case media_item.type do
      "movie" -> length(files)
      "tv_show" -> 1 + length(files) + length(detect_season_folders(files, library_path))
      _ -> 0
    end
  end

  # Private helpers

  defp get_active_media_files(%MediaItem{} = media_item, %LibraryPath{} = library_path) do
    case media_item.media_files do
      %Ecto.Association.NotLoaded{} ->
        []

      media_files ->
        Enum.filter(media_files, fn mf ->
          is_nil(mf.trashed_at) and mf.library_path_id == library_path.id and
            not is_nil(mf.relative_path)
        end)
    end
  end

  defp get_episode(media_file, episodes_by_id) do
    case media_file.episode_id do
      nil -> nil
      episode_id -> Map.get(episodes_by_id, episode_id)
    end
  end

  defp find_show_root_parts(parts) when length(parts) < 2, do: []

  defp find_show_root_parts(parts) do
    # Walk the path segments, looking for a season folder.
    # Everything before the season folder (except the filename) is the show root.
    # If no season folder is found, use the first directory as the show root.
    {show_parts, _found_season} =
      parts
      # Drop the filename (last element)
      |> Enum.slice(0..-2//1)
      |> Enum.reduce({[], false}, fn part, {acc, found_season} ->
        if found_season do
          {acc, true}
        else
          case PathParser.parse_season_folder(part) do
            {:ok, _season_number} -> {acc, true}
            :error -> {acc ++ [part], false}
          end
        end
      end)

    show_parts
  end

  defp find_season_folder_info(parts, library_base_path) do
    # Walk path parts (excluding filename) looking for a season folder segment
    parts
    |> Enum.slice(0..-2//1)
    |> Enum.with_index()
    |> Enum.flat_map(fn {part, index} ->
      case PathParser.parse_season_folder(part) do
        {:ok, season_number} ->
          # The season folder path includes all parts up to and including this segment
          season_folder_parts = Enum.take(parts, index + 1)
          season_path = Path.join([library_base_path | season_folder_parts])
          [{season_number, season_path}]

        :error ->
          []
      end
    end)
  end

  defp find_season_info(%MediaItem{metadata: %MediaMetadata{seasons: seasons}}, season_number)
       when is_list(seasons) do
    Enum.find(seasons, fn s -> s.season_number == season_number end)
  end

  defp find_season_info(_media_item, _season_number), do: nil

  # XML Building Helpers

  defp build_xml(root_element, children) do
    content =
      children
      |> List.flatten()
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    """
    <?xml version="1.0" encoding="utf-8" standalone="yes"?>
    <!-- Generated by Mydia -->
    <#{root_element}>
    #{content}
    </#{root_element}>
    """
  end

  defp xml_element(_tag, nil), do: nil
  defp xml_element(_tag, ""), do: nil

  defp xml_element(tag, value) do
    "  <#{tag}>#{xml_escape(to_string(value))}</#{tag}>"
  end

  defp xml_repeated(_tag, []), do: nil

  defp xml_repeated(tag, values) do
    Enum.map(values, fn value -> xml_element(tag, value) end)
  end

  defp xml_uniqueids(%MediaItem{} = media_item, %MediaMetadata{} = meta) do
    [
      xml_uniqueid("tmdb", media_item.tmdb_id),
      xml_uniqueid("tvdb", media_item.tvdb_id),
      xml_uniqueid("imdb", meta.imdb_id)
    ]
  end

  defp xml_uniqueid(_type, nil), do: nil

  defp xml_uniqueid(type, value) do
    "  <uniqueid type=\"#{type}\">#{xml_escape(to_string(value))}</uniqueid>"
  end

  defp xml_cast([]), do: nil

  defp xml_cast(cast_members) do
    Enum.map(cast_members, fn member ->
      role_element =
        if member.character do
          "\n    <role>#{xml_escape(member.character)}</role>"
        else
          ""
        end

      "  <actor>\n    <name>#{xml_escape(member.name)}</name>#{role_element}\n  </actor>"
    end)
  end

  defp xml_escape(nil), do: ""

  defp xml_escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp format_date(nil), do: nil
  defp format_date(%Date{} = date), do: Date.to_iso8601(date)
  defp format_date(date) when is_binary(date), do: date
end
