defmodule Mydia.Library.PathParser do
  @moduledoc """
  Parses folder structure to extract media metadata from library paths.

  ## TV Shows

  For files in structured TV library paths like `/media/tv/{Show Name}/Season {XX}/`,
  this module prioritizes folder structure over filename parsing for show identification.

  ### Why Folder Structure Matters

  Many media files have non-standard filenames that don't match their actual content:
  - `Playdate 2025 2160p AMZN WEB-DL...` (in Bluey folder - wrong filename)
  - `Robin.Hood.2025.S01E01...` (in Robin Hood folder - year causes issues)
  - `One-Punch.Man.S03E04...` vs `One.Punch.Man.S03E02...` (inconsistent naming)

  When files are organized in standard TV library structure, the folder name is
  authoritative and should be used for metadata matching.

  ### TV Folder Patterns Recognized

  Show name folder patterns:
  - `/media/tv/The Office/...` → "The Office"
  - `/media/tv/One-Punch Man/...` → "One-Punch Man"

  Season folder patterns:
  - `Season 01` → season 1
  - `Season 1` → season 1
  - `S01` → season 1
  - `Season.01` → season 1
  - `Specials` → season 0

  ## Movies

  For files in structured movie library paths like `/media/movies/{Movie Title (Year) [tmdb-ID]}/`,
  folder names are parsed to extract title, year, and external provider IDs.

  ### Movie Folder Patterns Recognized

  - `Twister (1996)` → title: "Twister", year: 1996
  - `Twister (1996) [tmdb-664]` → title: "Twister", year: 1996, external_id: "664", external_provider: :tmdb
  - `The Matrix [tmdb-603]` → title: "The Matrix", external_id: "603", external_provider: :tmdb
  - `Movie Name (2020) [imdb-tt1234567]` → title: "Movie Name", year: 2020, external_id: "tt1234567", external_provider: :imdb
  """

  require Logger

  @doc """
  Reads a season number out of one path segment.

  The single seam every season-folder decision goes through. `PathAnchor` calls
  it while clustering and this module's own path walkers call it, so widening the
  patterns (other languages, decorated folders, bare numerics) changes one place.
  """
  @spec season_from_segment(String.t()) :: {:ok, non_neg_integer()} | :error
  def season_from_segment(segment) when is_binary(segment) do
    if Regex.match?(specials_pattern(), segment) do
      {:ok, 0}
    else
      Enum.find_value(season_patterns(), :error, fn pattern ->
        case Regex.run(pattern, segment) do
          [_, number] -> {:ok, String.to_integer(number)}
          _ -> nil
        end
      end)
    end
  end

  def season_from_segment(_), do: :error

  # Define season patterns as a function to avoid module attribute compilation issues
  defp season_patterns do
    [
      # "Season 01", "Season 1", "Season.01", "Season.1"
      ~r/^Season[\s._-]?0?(\d{1,2})$/i,
      # "S01", "S1"
      ~r/^S0?(\d{1,2})$/i,
      # "Specials" - treated as season 0
      ~r/^Specials?$/i
    ]
  end

  defp specials_pattern, do: ~r/^Specials?$/i

  @doc """
  Extracts show name and season number from a file path.

  Returns a map with `:show_name` and `:season` keys if folder structure
  indicates a TV show path, or nil if no TV structure is detected.

  ## Examples

      iex> PathParser.extract_from_path("/media/tv/The Office/Season 02/episode.mkv")
      %{show_name: "The Office", season: 2}

      iex> PathParser.extract_from_path("/media/tv/Bluey/Season 03/Playdate 2025.mkv")
      %{show_name: "Bluey", season: 3}

      iex> PathParser.extract_from_path("/downloads/random_file.mkv")
      nil
  """
  @spec extract_from_path(String.t()) :: %{show_name: String.t(), season: integer() | nil} | nil
  def extract_from_path(path) when is_binary(path) do
    # Split path into segments
    segments = path |> Path.split() |> Enum.reject(&(&1 == "/" || &1 == ""))

    # We need at least 3 segments: parent/show_name/season/file or parent/show_name/file
    # Minimum: something/show_name/file.mkv
    if length(segments) < 2 do
      nil
    else
      # Get the directory path (remove filename)
      dir_segments = Enum.drop(segments, -1)

      # Try to find a season folder and show name folder
      case find_tv_structure(dir_segments) do
        {:ok, show_name, season} ->
          Logger.debug("Extracted TV structure from path",
            path: path,
            show_name: show_name,
            season: season
          )

          %{show_name: show_name, season: season}

        :error ->
          nil
      end
    end
  end

  def extract_from_path(_), do: nil

  @doc """
  Checks if a folder name matches a season pattern.

  ## Examples

      iex> PathParser.parse_season_folder("Season 01")
      {:ok, 1}

      iex> PathParser.parse_season_folder("S03")
      {:ok, 3}

      iex> PathParser.parse_season_folder("Specials")
      {:ok, 0}

      iex> PathParser.parse_season_folder("The Office")
      :error
  """
  @spec parse_season_folder(String.t()) :: {:ok, integer()} | :error
  def parse_season_folder(folder_name) when is_binary(folder_name) do
    season_from_segment(folder_name)
  end

  def parse_season_folder(_), do: :error

  # Movie folder pattern: "Movie Title (Year) [provider-id]" or just "Movie Title (Year)"
  # Captures: 1=title, 2=year (optional), 3=provider (optional), 4=id (optional)
  # Examples:
  #   "Twister (1996)" -> title="Twister", year=1996
  #   "Twister (1996) [tmdb-664]" -> title="Twister", year=1996, provider=tmdb, id=664
  #   "The Matrix [tmdb-603]" -> title="The Matrix", provider=tmdb, id=603
  defp movie_folder_pattern do
    ~r/^(.+?)\s*(?:\((\d{4})\))?\s*(?:\[(tmdb|tvdb|imdb)-([^\]]+)\])?\s*$/i
  end

  # TV show folder pattern: "Show Name (Year) [provider-id]" or just "Show Name [provider-id]"
  # This pattern is the same as movie_folder_pattern but is used in a TV context
  # Captures: 1=title, 2=year (optional), 3=provider (optional), 4=id (optional)
  # Examples:
  #   "Breaking Bad [tvdb-81189]" -> title="Breaking Bad", provider=tvdb, id=81189
  #   "The Office (2005) [tmdb-2316]" -> title="The Office", year=2005, provider=tmdb, id=2316
  #   "Bluey (2018)" -> title="Bluey", year=2018
  defp tv_show_folder_pattern do
    ~r/^(.+?)\s*(?:\((\d{4})\))?\s*(?:\[(tmdb|tvdb|imdb)-([^\]]+)\])?\s*$/i
  end

  @doc """
  Extracts movie metadata from a folder name.

  Returns a map with `:title`, `:year`, `:external_id`, and `:external_provider` keys
  if the folder name matches a recognized movie pattern, or nil otherwise.

  ## Examples

      iex> PathParser.parse_movie_folder("Twister (1996) [tmdb-664]")
      %{title: "Twister", year: 1996, external_id: "664", external_provider: :tmdb}

      iex> PathParser.parse_movie_folder("The Matrix (1999)")
      %{title: "The Matrix", year: 1999, external_id: nil, external_provider: nil}

      iex> PathParser.parse_movie_folder("Inception [tmdb-27205]")
      %{title: "Inception", year: nil, external_id: "27205", external_provider: :tmdb}

      iex> PathParser.parse_movie_folder("random_file")
      nil
  """
  @spec parse_movie_folder(String.t()) :: map() | nil
  def parse_movie_folder(folder_name) when is_binary(folder_name) do
    case Regex.run(movie_folder_pattern(), folder_name) do
      [_full, title | rest] ->
        title = String.trim(title)

        # rest can be [year, provider, id], [year], [nil, provider, id], etc.
        {year, external_provider, external_id} = extract_movie_folder_parts(rest)

        # Only return result if we have at least a title AND (year OR external_id)
        # This avoids false matches on random folder names
        if String.length(title) >= 2 and (year != nil or external_id != nil) do
          %{
            title: title,
            year: year,
            external_id: external_id,
            external_provider: external_provider
          }
        else
          nil
        end

      _ ->
        nil
    end
  end

  def parse_movie_folder(_), do: nil

  @doc """
  Extracts TV show metadata from a folder name.

  Returns a map with `:title`, `:year`, `:external_id`, and `:external_provider` keys
  if the folder name matches a recognized TV show pattern, or nil otherwise.

  Unlike parse_movie_folder, this function is more lenient - it will return a result
  even if only a title is found (no year or external ID required), since TV show
  folder names often just contain the show name.

  ## Examples

      iex> PathParser.parse_tv_show_folder("Breaking Bad [tvdb-81189]")
      %{title: "Breaking Bad", year: nil, external_id: "81189", external_provider: :tvdb}

      iex> PathParser.parse_tv_show_folder("The Office (2005) [tmdb-2316]")
      %{title: "The Office", year: 2005, external_id: "2316", external_provider: :tmdb}

      iex> PathParser.parse_tv_show_folder("Bluey (2018)")
      %{title: "Bluey", year: 2018, external_id: nil, external_provider: nil}

      iex> PathParser.parse_tv_show_folder("One-Punch Man")
      %{title: "One-Punch Man", year: nil, external_id: nil, external_provider: nil}
  """
  @spec parse_tv_show_folder(String.t()) :: map() | nil
  def parse_tv_show_folder(folder_name) when is_binary(folder_name) do
    case Regex.run(tv_show_folder_pattern(), folder_name) do
      [_full, title | rest] ->
        title = String.trim(title)

        # rest can be [year, provider, id], [year], [nil, provider, id], etc.
        {year, external_provider, external_id} = extract_movie_folder_parts(rest)

        # For TV shows, we're more lenient - return result if we have at least a valid title
        # This is because TV show folders might just be "Show Name" with metadata in subfolders
        if String.length(title) >= 2 do
          %{
            title: title,
            year: year,
            external_id: external_id,
            external_provider: external_provider
          }
        else
          nil
        end

      _ ->
        nil
    end
  end

  def parse_tv_show_folder(_), do: nil

  # Extract year, provider, and id from regex captures
  defp extract_movie_folder_parts([]), do: {nil, nil, nil}

  defp extract_movie_folder_parts([year_str]) do
    {parse_year(year_str), nil, nil}
  end

  defp extract_movie_folder_parts([year_str, provider_str, id_str]) do
    year = parse_year(year_str)
    {provider, id} = parse_provider_id(provider_str, id_str)
    {year, provider, id}
  end

  defp extract_movie_folder_parts([year_str, provider_str]) do
    {parse_year(year_str), parse_provider(provider_str), nil}
  end

  defp extract_movie_folder_parts(_), do: {nil, nil, nil}

  defp parse_year(nil), do: nil
  defp parse_year(""), do: nil

  defp parse_year(year_str) when is_binary(year_str) do
    case Integer.parse(year_str) do
      {year, ""} when year >= 1900 and year <= 2100 -> year
      _ -> nil
    end
  end

  defp parse_provider_id(nil, _), do: {nil, nil}
  defp parse_provider_id(_, nil), do: {nil, nil}
  defp parse_provider_id("", _), do: {nil, nil}
  defp parse_provider_id(_, ""), do: {nil, nil}

  defp parse_provider_id(provider_str, id_str) do
    provider =
      case String.downcase(provider_str) do
        "tmdb" -> :tmdb
        "tvdb" -> :tvdb
        "imdb" -> :imdb
        _ -> nil
      end

    {provider, id_str}
  end

  defp parse_provider(nil), do: nil
  defp parse_provider(""), do: nil

  defp parse_provider(provider_str) do
    case String.downcase(provider_str) do
      "tmdb" -> :tmdb
      "tvdb" -> :tvdb
      "imdb" -> :imdb
      _ -> nil
    end
  end

  @doc """
  Extracts movie metadata from a file path by examining folder structure.

  Looks at the parent folder of the file to extract movie metadata.
  Returns a map with movie metadata if found, or nil otherwise.

  ## Examples

      iex> PathParser.extract_movie_from_path("/media/movies/Twister (1996) [tmdb-664]/Twister.1996.mkv")
      %{title: "Twister", year: 1996, external_id: "664", external_provider: :tmdb}

      iex> PathParser.extract_movie_from_path("/downloads/random_movie.mkv")
      nil
  """
  @spec extract_movie_from_path(String.t()) :: map() | nil
  def extract_movie_from_path(path) when is_binary(path) do
    # Get the parent folder of the file
    parent_folder = path |> Path.dirname() |> Path.basename()

    case parse_movie_folder(parent_folder) do
      %{} = result ->
        Logger.debug("Extracted movie metadata from folder",
          path: path,
          folder: parent_folder,
          title: result.title,
          year: result.year,
          external_id: result.external_id,
          external_provider: result.external_provider
        )

        result

      nil ->
        nil
    end
  end

  def extract_movie_from_path(_), do: nil

  @doc """
  Extracts TV show metadata from a file path by examining the show folder.

  Looks at the show folder (parent of season folder) to extract external provider IDs.
  This is used to enhance TV show matching when folder names contain [tvdb-123] or similar.

  Returns a map with `:title`, `:year`, `:external_id`, and `:external_provider` keys
  if a TV show folder with metadata is found, or nil otherwise.

  ## Examples

      iex> PathParser.extract_tv_show_from_path("/media/tv/Breaking Bad [tvdb-81189]/Season 01/episode.mkv")
      %{title: "Breaking Bad", year: nil, external_id: "81189", external_provider: :tvdb}

      iex> PathParser.extract_tv_show_from_path("/media/tv/The Office (2005) [tmdb-2316]/Season 02/episode.mkv")
      %{title: "The Office", year: 2005, external_id: "2316", external_provider: :tmdb}

      iex> PathParser.extract_tv_show_from_path("/media/tv/Bluey/Season 03/episode.mkv")
      %{title: "Bluey", year: nil, external_id: nil, external_provider: nil}

      iex> PathParser.extract_tv_show_from_path("/downloads/random_file.mkv")
      nil
  """
  @spec extract_tv_show_from_path(String.t()) :: map() | nil
  def extract_tv_show_from_path(path) when is_binary(path) do
    # Split path into segments
    segments = path |> Path.split() |> Enum.reject(&(&1 == "/" || &1 == ""))

    # We need at least 3 segments: parent/show_name/season/file
    if length(segments) < 3 do
      nil
    else
      # Get the directory path (remove filename)
      dir_segments = Enum.drop(segments, -1)

      # Find the show name folder (the folder before the season folder)
      case find_show_folder(dir_segments) do
        {:ok, show_folder_name} ->
          # Parse the show folder to extract metadata
          case parse_tv_show_folder(show_folder_name) do
            %{} = result ->
              Logger.debug("Extracted TV show metadata from folder",
                path: path,
                folder: show_folder_name,
                title: result.title,
                year: result.year,
                external_id: result.external_id,
                external_provider: result.external_provider
              )

              result

            nil ->
              nil
          end

        :error ->
          nil
      end
    end
  end

  def extract_tv_show_from_path(_), do: nil

  # Finds the show folder by looking for the folder before the season folder
  defp find_show_folder(dir_segments) do
    dir_segments
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(:error, fn {segment, index} ->
      case parse_season_folder(segment) do
        {:ok, _season} ->
          # Found a season folder - the show name should be the segment before it
          if index > 0 do
            show_folder = Enum.at(dir_segments, index - 1)

            # Validate show name is reasonable (not a root folder)
            if valid_show_name?(show_folder) do
              {:ok, show_folder}
            else
              nil
            end
          else
            nil
          end

        :error ->
          nil
      end
    end)
  end

  @doc """
  Checks if a path appears to be a TV show library path.

  Returns true if the path contains a recognizable TV show folder structure.

  ## Examples

      iex> PathParser.is_tv_path?("/media/tv/The Office/Season 01/episode.mkv")
      true

      iex> PathParser.is_tv_path?("/downloads/Movie.2020.1080p.mkv")
      false
  """
  @spec is_tv_path?(String.t()) :: boolean()
  def is_tv_path?(path) when is_binary(path) do
    extract_from_path(path) != nil
  end

  def is_tv_path?(_), do: false

  # Private helpers

  # Finds TV structure by looking for season folder and inferring show name
  defp find_tv_structure(dir_segments) do
    # Work backwards through segments to find the season folder
    dir_segments
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(:error, fn {segment, index} ->
      case parse_season_folder(segment) do
        {:ok, season} ->
          # Found a season folder - the show name should be the segment before it
          if index > 0 do
            show_name = Enum.at(dir_segments, index - 1)

            # Validate show name is reasonable (not a root folder like "media" or "tv")
            if valid_show_name?(show_name) do
              {:ok, show_name, season}
            else
              nil
            end
          else
            nil
          end

        :error ->
          nil
      end
    end)
  end

  # Validates that a folder name is likely a show name and not a system/root folder
  defp valid_show_name?(name) when is_binary(name) do
    # Reject common root folder names
    root_folders =
      ~w(media tv shows series television video videos library content data home usr mnt)

    normalized = String.downcase(name)

    # Show name should:
    # - Not be a common root folder
    # - Be at least 2 characters
    # - Not start with a dot (hidden folders)
    normalized not in root_folders &&
      String.length(name) >= 2 &&
      not String.starts_with?(name, ".")
  end

  defp valid_show_name?(_), do: false
end
