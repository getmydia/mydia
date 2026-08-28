defmodule Mydia.Library.SampleDetector do
  @moduledoc """
  Detects sample files, trailers, and extras in media collections.

  Uses a multi-layered approach following industry conventions from Sonarr,
  Radarr, and Plex:

  1. Folder exclusion - Files in Plex extras directories
  2. Filename pattern matching - Common suffixes like -sample, -trailer
  3. Runtime detection - Files shorter than expected duration thresholds

  ## Detection Priority

  Folder detection takes priority over filename detection, as folder organization
  provides stronger signals about content intent.
  """

  alias Mydia.Library.Structs.ParsedFileInfo

  @doc """
  Detects if a file is a sample, trailer, or extra based on its path.

  Returns a map with detection results:
  - `:is_sample` - true if detected as a sample file
  - `:is_trailer` - true if detected as a trailer
  - `:is_extra` - true if detected as bonus/extra content
  - `:detection_method` - :filename, :folder, or nil
  - `:detected_folder` - the folder name if detected via folder

  ## Examples

      iex> detect("/movies/Avatar/Sample/avatar-sample.mkv")
      %{is_sample: true, is_trailer: false, is_extra: false,
        detection_method: :folder, detected_folder: "Sample"}

      iex> detect("/movies/Avatar/avatar-trailer.mkv")
      %{is_sample: false, is_trailer: true, is_extra: false,
        detection_method: :filename, detected_folder: nil}
  """
  @spec detect(String.t()) :: %{
          is_sample: boolean(),
          is_trailer: boolean(),
          is_extra: boolean(),
          detection_method: ParsedFileInfo.detection_method(),
          detected_folder: String.t() | nil
        }
  def detect(path) when is_binary(path) do
    # Check folder-based detection first (higher priority)
    case detect_by_folder(path) do
      nil ->
        # Fall back to filename-based detection
        detect_by_filename(path)

      result ->
        result
    end
  end

  @doc """
  Checks if a file appears to be a sample based on its duration.

  Uses runtime thresholds from Sonarr/Radarr:
  - Files with 0 duration are always considered samples
  - For TV shows, uses expected episode duration to determine threshold
  - For movies, minimum threshold is 600 seconds (10 minutes)

  ## Options

  - `:expected_type` - :movie or :tv_show (defaults to :unknown)
  - `:expected_duration` - Expected duration in seconds for the content type

  ## Examples

      iex> sample_by_duration?(45.0, expected_type: :movie)
      true

      iex> sample_by_duration?(3600.0, expected_type: :movie)
      false

      iex> sample_by_duration?(nil)
      false
  """
  @spec sample_by_duration?(float() | nil, keyword()) :: boolean()
  def sample_by_duration?(duration, opts \\ [])

  def sample_by_duration?(nil, _opts), do: false

  def sample_by_duration?(duration, opts) when is_number(duration) do
    # Zero duration is always a sample
    if duration <= 0 do
      true
    else
      expected_type = Keyword.get(opts, :expected_type, :unknown)
      expected_duration = Keyword.get(opts, :expected_duration)

      min_duration = calculate_min_duration(expected_type, expected_duration)
      duration < min_duration
    end
  end

  @doc """
  Checks if a path is excluded from sample detection.

  Certain file types should skip sample detection:
  - `.flv` files
  - `.strm` files (streaming URLs)
  - DVD/Blu-ray images: `.iso`, `.img`

  Note: `.m2ts` is included in skip list per Sonarr convention.

  ## Examples

      iex> skip_detection?("/movies/movie.strm")
      true

      iex> skip_detection?("/movies/movie.mkv")
      false
  """
  @spec skip_detection?(String.t()) :: boolean()
  def skip_detection?(path) when is_binary(path) do
    extension =
      path
      |> Path.extname()
      |> String.downcase()

    extension in [".flv", ".strm", ".iso", ".img", ".m2ts"]
  end

  @doc """
  Applies sample/trailer/extra detection to a ParsedFileInfo struct.

  This is a convenience function that takes a ParsedFileInfo and the original
  file path, runs detection, and returns an updated struct with detection fields.

  ## Examples

      iex> info = %ParsedFileInfo{type: :movie, ...}
      iex> apply_detection(info, "/movies/Movie/Sample/movie-sample.mkv")
      %ParsedFileInfo{is_sample: true, detection_method: :folder, ...}
  """
  @spec apply_detection(ParsedFileInfo.t(), String.t()) :: ParsedFileInfo.t()
  def apply_detection(%ParsedFileInfo{} = info, path) when is_binary(path) do
    if skip_detection?(path) do
      info
    else
      detection = detect(path)

      %{
        info
        | is_sample: detection.is_sample,
          is_trailer: detection.is_trailer,
          is_extra: detection.is_extra,
          detection_method: detection.detection_method,
          detected_folder: detection.detected_folder
      }
    end
  end

  @doc """
  Checks if the detection indicates the file should be excluded from import.

  Returns true if any of is_sample, is_trailer, or is_extra is true.
  """
  @spec excluded?(map()) :: boolean()
  def excluded?(detection) when is_map(detection) do
    detection[:is_sample] == true or
      detection[:is_trailer] == true or
      detection[:is_extra] == true
  end

  @doc """
  Returns a human-readable reason for why a file was excluded.
  """
  @spec exclusion_reason(map()) :: String.t() | nil
  def exclusion_reason(detection) when is_map(detection) do
    cond do
      detection[:is_sample] ->
        case detection[:detection_method] do
          :folder -> "Sample file (in #{detection[:detected_folder]} folder)"
          :filename -> "Sample file (detected from filename)"
          :duration -> "Sample file (too short)"
          _ -> "Sample file"
        end

      detection[:is_trailer] ->
        case detection[:detection_method] do
          :folder -> "Trailer (in #{detection[:detected_folder]} folder)"
          :filename -> "Trailer (detected from filename)"
          _ -> "Trailer"
        end

      detection[:is_extra] ->
        case detection[:detection_method] do
          :folder -> "Extra content (in #{detection[:detected_folder]} folder)"
          :filename -> "Extra content (detected from filename)"
          _ -> "Extra content"
        end

      true ->
        nil
    end
  end

  @doc """
  Translates a `detect/1` result into `{extra_kind, extra_source}` columns.

  Returns `nil` when nothing was detected, meaning the file is a version.

  Folder detections carry a named kind, because the Plex folder names map
  directly onto the enum. Filename detections do not: `@extra_pattern` is a
  single combined regex that does not report which alternative matched, so
  naming a kind from it would be a guess. They land on `:other`.
  """
  @spec extra_kind(map()) :: {atom(), :folder | :filename} | nil
  def extra_kind(detection) when is_map(detection) do
    source = detection[:detection_method]

    cond do
      detection[:is_sample] ->
        {:sample, source}

      detection[:is_trailer] ->
        {:trailer, source}

      detection[:is_extra] and source == :folder ->
        {kind_from_folder(detection[:detected_folder]), :folder}

      detection[:is_extra] ->
        {:other, source}

      true ->
        nil
    end
  end

  @folder_kinds %{
    "behind the scenes" => :behind_the_scenes,
    "deleted scenes" => :deleted_scene,
    "featurettes" => :featurette,
    "interviews" => :interview,
    "scenes" => :scene,
    "shorts" => :short,
    "other" => :other,
    "extras" => :other
  }

  defp kind_from_folder(nil), do: :other

  defp kind_from_folder(folder), do: Map.get(@folder_kinds, String.downcase(folder), :other)

  ## Private Functions

  # Plex extras folder names (case-insensitive)
  # https://support.plex.tv/articles/local-files-for-trailers-and-extras/
  @extras_folders [
    "behind the scenes",
    "deleted scenes",
    "featurettes",
    "interviews",
    "scenes",
    "shorts",
    "other",
    "extras"
  ]

  @sample_folders ["sample", "samples"]

  @trailer_folders ["trailers", "trailer"]

  defp detect_by_folder(path) do
    # Split path into components and check each folder name
    path
    |> Path.split()
    |> Enum.find_value(fn component ->
      folder_name = String.downcase(component)

      cond do
        folder_name in @sample_folders ->
          %{
            is_sample: true,
            is_trailer: false,
            is_extra: false,
            detection_method: :folder,
            detected_folder: component
          }

        folder_name in @trailer_folders ->
          %{
            is_sample: false,
            is_trailer: true,
            is_extra: false,
            detection_method: :folder,
            detected_folder: component
          }

        folder_name in @extras_folders ->
          %{
            is_sample: false,
            is_trailer: false,
            is_extra: true,
            detection_method: :folder,
            detected_folder: component
          }

        true ->
          nil
      end
    end)
  end

  # Filename patterns for sample/trailer/extra detection
  # Matches suffixes before file extension (case-insensitive):
  # - Separators: - _ . or space
  # - Keywords: sample, trailer, featurette, etc.

  # Sample patterns: -sample, _sample, .sample, " sample"
  @sample_pattern ~r/[.\-_\s]sample(?:\s*\d+)?$/i

  # Trailer patterns: -trailer, _trailer, .trailer, " trailer"
  @trailer_pattern ~r/[.\-_\s]trailer(?:\s*\d+)?$/i

  # Extra/bonus patterns - combined into a single regex for efficiency
  @extra_pattern ~r/[.\-_\s](?:featurette(?:\s*\d+)?|deleted(?:\s+scenes?)?|behind\s*the\s*scenes?|interview(?:s)?|(?:bonus|extra)(?:\s*\d+)?|short(?:s)?|other|scene(?:s)?(?:\s*\d+)?)$/i

  defp detect_by_filename(path) do
    # Get filename without extension
    filename =
      path
      |> Path.basename()
      |> Path.rootname()

    cond do
      Regex.match?(@sample_pattern, filename) ->
        %{
          is_sample: true,
          is_trailer: false,
          is_extra: false,
          detection_method: :filename,
          detected_folder: nil
        }

      Regex.match?(@trailer_pattern, filename) ->
        %{
          is_sample: false,
          is_trailer: true,
          is_extra: false,
          detection_method: :filename,
          detected_folder: nil
        }

      Regex.match?(@extra_pattern, filename) ->
        %{
          is_sample: false,
          is_trailer: false,
          is_extra: true,
          detection_method: :filename,
          detected_folder: nil
        }

      true ->
        %{
          is_sample: false,
          is_trailer: false,
          is_extra: false,
          detection_method: nil,
          detected_folder: nil
        }
    end
  end

  # Calculate minimum duration threshold based on content type
  # Following Sonarr/Radarr conventions
  defp calculate_min_duration(:tv_show, expected_duration) when is_number(expected_duration) do
    cond do
      # Anime shorts (≤3 min expected): minimum 15 seconds
      expected_duration <= 180 -> 15
      # Webisodes (≤10 min expected): minimum 90 seconds
      expected_duration <= 600 -> 90
      # 30-minute content: minimum 5 minutes (300 seconds)
      expected_duration <= 1800 -> 300
      # Standard content: minimum 10 minutes (600 seconds)
      true -> 600
    end
  end

  defp calculate_min_duration(:tv_show, _), do: 300

  defp calculate_min_duration(:movie, _), do: 600

  defp calculate_min_duration(_, _), do: 600
end
