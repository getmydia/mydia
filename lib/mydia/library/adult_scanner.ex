defmodule Mydia.Library.AdultScanner do
  @moduledoc """
  Scans and processes adult content files in library paths.

  Handles:
  - Scanning for video files
  - Extracting technical metadata from video files (via FFprobe)
  - Parsing filenames for studio, title, and performer information
  - Creating Studio, Scene, and AdultFile records
  - Matching files to existing library items
  """

  require Logger

  import Ecto.Query, warn: false

  alias Mydia.{Adult, Repo}
  alias Mydia.Library.Scanner
  alias Mydia.Settings.LibraryPath

  @doc """
  Processes scan results for an adult content library path.

  Takes the raw scan result and creates/updates adult records in the database.
  """
  def process_scan_result(%LibraryPath{} = library_path, scan_result) do
    existing_files = Adult.list_adult_files(library_path_id: library_path.id)

    # Detect changes using the shared scanner logic
    changes = Scanner.detect_changes(scan_result, existing_files, library_path)

    Logger.info("Processing adult library changes",
      new_files: length(changes.new_files),
      modified_files: length(changes.modified_files),
      deleted_files: length(changes.deleted_files)
    )

    # Process new files
    new_results = Enum.map(changes.new_files, &process_new_file(&1, library_path))

    # Process modified files (re-read metadata)
    Enum.each(changes.modified_files, &process_modified_file(&1, library_path))

    # Delete removed files
    Enum.each(changes.deleted_files, &delete_adult_file/1)

    %{
      new_files: length(changes.new_files),
      modified_files: length(changes.modified_files),
      deleted_files: length(changes.deleted_files),
      new_results: new_results
    }
  end

  @doc """
  Parses a filename to extract studio, title, and performers.

  Supports common naming patterns:
  - "Studio - Scene Title (2023).mp4"
  - "Studio - Performer1, Performer2 - Title.mp4"
  - "Studio.Scene.Title.XXX.1080p.mp4"
  - Plain filename without structure

  Returns a map with :studio, :title, :performers, and :year keys.
  """
  def parse_filename(filename) do
    # Remove extension
    name = Path.basename(filename, Path.extname(filename))

    # Try different patterns
    result =
      try_pattern_studio_dash_performers_dash_title(name) ||
        try_pattern_studio_dash_title_with_year(name) ||
        try_pattern_dotted(name) ||
        fallback_parse(name)

    # Clean up the result
    %{
      studio: clean_string(result[:studio]),
      title: clean_string(result[:title]) || name,
      performers: result[:performers] || [],
      year: result[:year]
    }
  end

  ## Private Functions

  defp process_new_file(file_info, library_path) do
    relative_path = Path.relative_to(file_info.path, library_path.path)

    # Parse filename for metadata
    parsed = parse_filename(file_info.filename)

    # Find or create studio if we have a studio name
    studio = if parsed.studio, do: find_or_create_studio(parsed.studio)

    # Find or create scene
    scene = find_or_create_scene(parsed, studio)

    # Create adult file record. Tech metadata (codec/resolution/bitrate/...) is
    # left nil at import time; the background analysis worker is responsible
    # for filling it in.
    case create_adult_file(file_info, relative_path, library_path, scene) do
      {:ok, adult_file} ->
        Logger.debug("Created adult file record",
          path: relative_path,
          studio: parsed.studio,
          title: parsed.title
        )

        {:ok, adult_file}

      {:error, changeset} ->
        Logger.error("Failed to create adult file",
          path: relative_path,
          errors: inspect(changeset.errors)
        )

        {:error, changeset}
    end
  end

  defp process_modified_file(file_info, library_path) do
    relative_path = Path.relative_to(file_info.path, library_path.path)

    case Adult.get_adult_file_by_path(file_info.path) do
      nil ->
        # File was somehow not in DB, process as new
        process_new_file(file_info, library_path)

      adult_file ->
        # Update size only; tech metadata is left alone here so we do not
        # clobber existing analysis results, and we do not run ffprobe inline
        # on the scan path.
        Adult.update_adult_file(adult_file, %{size: file_info.size})

        Logger.debug("Updated adult file", path: relative_path)
    end
  end

  defp delete_adult_file(adult_file) do
    case Adult.delete_adult_file(adult_file) do
      {:ok, _} ->
        Logger.debug("Deleted adult file record", id: adult_file.id)

      {:error, reason} ->
        Logger.error("Failed to delete adult file",
          id: adult_file.id,
          reason: inspect(reason)
        )
    end
  end

  defp find_or_create_studio(name) do
    case Adult.get_studio_by_name(name) do
      nil ->
        {:ok, studio} =
          Adult.create_studio(%{
            name: name,
            sort_name: generate_sort_name(name)
          })

        studio

      studio ->
        studio
    end
  end

  defp find_or_create_scene(parsed, studio) do
    title = parsed.title || "Unknown Scene"
    studio_id = if studio, do: studio.id

    # For now, create a new scene for each unique title/studio combo
    # In the future, we could add matching logic based on StashDB etc
    existing =
      Mydia.Adult.Scene
      |> where([s], s.title == ^title)
      |> maybe_filter_studio(studio_id)
      |> Repo.one()

    case existing do
      nil ->
        {:ok, scene} =
          Adult.create_scene(%{
            title: title,
            studio_id: studio_id,
            performers: parsed.performers,
            release_date: parse_year_to_date(parsed.year)
          })

        scene

      scene ->
        # Update performers if we have new ones and scene has none
        if parsed.performers != [] and scene.performers == [] do
          {:ok, updated} = Adult.update_scene(scene, %{performers: parsed.performers})
          updated
        else
          scene
        end
    end
  end

  defp maybe_filter_studio(query, nil), do: where(query, [s], is_nil(s.studio_id))
  defp maybe_filter_studio(query, studio_id), do: where(query, [s], s.studio_id == ^studio_id)

  defp create_adult_file(file_info, relative_path, library_path, scene) do
    Adult.create_adult_file(%{
      path: file_info.path,
      relative_path: relative_path,
      size: file_info.size,
      library_path_id: library_path.id,
      scene_id: if(scene, do: scene.id)
    })
  end

  # Pattern: "Studio - Performer1, Performer2 - Title"
  defp try_pattern_studio_dash_performers_dash_title(name) do
    case String.split(name, " - ", parts: 3) do
      [studio, performers_str, title] when byte_size(studio) > 0 and byte_size(title) > 0 ->
        performers = parse_performers(performers_str)

        if performers != [] do
          %{studio: studio, title: title, performers: performers, year: nil}
        else
          nil
        end

      _ ->
        nil
    end
  end

  # Pattern: "Studio - Scene Title (2023)"
  defp try_pattern_studio_dash_title_with_year(name) do
    case Regex.run(~r/^(.+?)\s+-\s+(.+?)(?:\s+\((\d{4})\))?$/, name) do
      [_, studio, title] ->
        %{studio: studio, title: title, performers: [], year: nil}

      [_, studio, title, year] ->
        %{studio: studio, title: title, performers: [], year: parse_year(year)}

      _ ->
        nil
    end
  end

  # Pattern: "Studio.Scene.Title.XXX.1080p" (dot-separated)
  defp try_pattern_dotted(name) do
    parts = String.split(name, ".")

    if length(parts) >= 3 do
      # Filter out quality indicators and common tags
      filtered =
        Enum.reject(parts, fn part ->
          downcased = String.downcase(part)

          Regex.match?(~r/^\d{3,4}p$/i, part) or
            downcased in ~w(xxx x264 x265 hevc h264 h265 hdrip webrip bluray webdl mp4 mkv avi)
        end)

      case filtered do
        [studio | rest] when rest != [] ->
          title = Enum.join(rest, " ")
          %{studio: studio, title: title, performers: [], year: nil}

        _ ->
          nil
      end
    else
      nil
    end
  end

  # Fallback: just use the filename as title
  defp fallback_parse(name) do
    # Try to extract year from the name
    case Regex.run(~r/\((\d{4})\)/, name) do
      [match, year] ->
        title = String.replace(name, match, "") |> String.trim()
        %{studio: nil, title: title, performers: [], year: parse_year(year)}

      _ ->
        %{studio: nil, title: name, performers: [], year: nil}
    end
  end

  defp parse_performers(performers_str) do
    performers_str
    |> String.split(~r/[,&]/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.length(&1) < 2))
  end

  defp parse_year(nil), do: nil
  defp parse_year(year) when is_binary(year), do: String.to_integer(year)
  defp parse_year(year) when is_integer(year), do: year

  defp parse_year_to_date(nil), do: nil
  defp parse_year_to_date(year), do: Date.new!(year, 1, 1)

  defp generate_sort_name(name) do
    name
    |> String.trim()
    |> String.replace(~r/^(The|A|An)\s+/i, "")
  end

  defp clean_string(nil), do: nil
  defp clean_string(str), do: String.trim(str)
end
