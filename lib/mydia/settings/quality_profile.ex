defmodule Mydia.Settings.QualityProfile do
  @moduledoc """
  Schema for quality profiles that define acceptable quality levels for media.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Mydia.Settings.JsonAtomMapType

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: binary(),
          name: String.t() | nil,
          upgrades_allowed: boolean(),
          upgrade_until_score: integer() | nil,
          min_upgrade_margin: integer() | nil,
          description: String.t() | nil,
          is_system: boolean(),
          version: integer(),
          source_url: String.t() | nil,
          last_synced_at: DateTime.t() | nil,
          quality_standards: map() | nil,
          media_files: [Mydia.Library.MediaFile.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  # Allowed values for quality standards validation
  @valid_video_codecs [
    "h264",
    "h265",
    "hevc",
    "x264",
    "x265",
    "av1",
    "vc1",
    "mpeg2",
    "xvid",
    "divx"
  ]
  @valid_audio_codecs [
    "aac",
    "ac3",
    "eac3",
    "dts",
    "dts-hd",
    "truehd",
    "atmos",
    "flac",
    "mp3",
    "opus"
  ]
  @valid_audio_channels ["1.0", "2.0", "2.1", "5.1", "6.1", "7.1", "7.1.2", "7.1.4"]
  @valid_resolutions ["360p", "480p", "576p", "720p", "1080p", "2160p", "4320p"]
  @valid_sources [
    "BluRay",
    "REMUX",
    "WEB-DL",
    "WEBRip",
    "HDTV",
    "SDTV",
    "DVD",
    "DVDRip",
    "BDRip"
  ]
  @valid_hdr_formats ["hdr10", "hdr10+", "dolby_vision", "hlg"]

  schema "quality_profiles" do
    field :name, :string
    field :upgrades_allowed, :boolean, default: true
    field :upgrade_until_score, :integer, default: 85
    field :min_upgrade_margin, :integer, default: 5

    # Enhanced fields for import/export and configuration management
    field :description, :string
    field :is_system, :boolean, default: false
    field :version, :integer, default: 1
    field :source_url, :string
    field :last_synced_at, :utc_datetime
    field :quality_standards, JsonAtomMapType

    has_many :media_files, Mydia.Library.MediaFile

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a quality profile.
  """
  def changeset(quality_profile, attrs) do
    quality_profile
    |> cast(attrs, [
      :name,
      :upgrades_allowed,
      :upgrade_until_score,
      :min_upgrade_margin,
      :description,
      :is_system,
      :version,
      :source_url,
      :last_synced_at,
      :quality_standards
    ])
    |> validate_required([:name])
    |> unique_constraint(:name)
    |> validate_quality_standards()
    |> validate_preferred_resolutions_present()
    |> validate_number(:upgrade_until_score,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    )
    |> validate_number(:min_upgrade_margin,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    )
  end

  @doc """
  Validates the quality_standards map structure and values.

  Expected structure:
  %{
    # Video codec preferences (priority ordered, first = most preferred)
    preferred_video_codecs: ["h265", "h264", "av1"],

    # Audio codec preferences (priority ordered, first = most preferred)
    preferred_audio_codecs: ["atmos", "truehd", "dts-hd", "ac3"],

    # Audio channel preferences (priority ordered)
    preferred_audio_channels: ["7.1", "5.1", "2.0"],

    # Resolution preferences (min/max/preferred)
    min_resolution: "720p",
    max_resolution: "2160p",
    preferred_resolutions: ["1080p", "2160p"],

    # Source preferences (priority ordered)
    preferred_sources: ["BluRay", "REMUX", "WEB-DL"],

    # File size guidelines (MB) - differentiated by media type
    movie_min_size_mb: 2048,
    movie_max_size_mb: 15360,
    episode_min_size_mb: 512,
    episode_max_size_mb: 4096,

    # HDR/Dolby Vision preferences
    hdr_formats: ["dolby_vision", "hdr10+", "hdr10"],
    require_hdr: false,

    # Torrent source preferences
    min_ratio: 0.2,  # minimum seeder/leecher ratio for torrents
  }
  """
  def validate_quality_standards(changeset) do
    case get_change(changeset, :quality_standards) do
      nil ->
        changeset

      standards when is_map(standards) ->
        changeset
        |> validate_video_codecs(standards)
        |> validate_audio_codecs(standards)
        |> validate_audio_channels(standards)
        |> validate_resolution_ranges(standards)
        |> validate_resolutions(standards)
        |> validate_sources(standards)
        |> validate_media_type_sizes(standards)
        |> validate_hdr_formats(standards)
        |> validate_min_ratio(standards)

      _ ->
        add_error(changeset, :quality_standards, "must be a map")
    end
  end

  @doc """
  Calculates a quality score for a media file based on the profile's quality standards.

  Returns a score between 0.0 and 100.0, where:
  - 100.0 = Perfect match for all criteria
  - 0.0 = Does not meet any criteria or violates constraints

  ## Parameters

    - `profile` - QualityProfile struct with quality_standards defined
    - `media_attrs` - Map containing media file attributes:
      - `:video_codec` - Video codec (e.g., "h265", "h264")
      - `:audio_codec` - Audio codec (e.g., "atmos", "ac3")
      - `:audio_channels` - Audio channels (e.g., "5.1", "7.1")
      - `:resolution` - Resolution (e.g., "1080p", "2160p")
      - `:source` - Source type (e.g., "BluRay", "WEB-DL")
      - `:file_size_mb` - File size in MB
      - `:media_type` - Either :movie or :episode
      - `:hdr_format` - HDR format if present (e.g., "dolby_vision", "hdr10")

  ## Returns

    A map with:
    - `:score` - Overall quality score (0.0 - 100.0)
    - `:breakdown` - Map with individual component scores
    - `:violations` - List of constraint violations (if any)

  ## Examples

      iex> score_media_file(profile, %{
        video_codec: "h265",
        audio_codec: "atmos",
        resolution: "1080p",
        file_size_mb: 8192,
        media_type: :movie
      })
      %{
        score: 95.5,
        breakdown: %{video_codec: 100.0, audio_codec: 100.0, ...},
        violations: []
      }
  """
  def score_media_file(%__MODULE__{quality_standards: nil}, _media_attrs) do
    %{score: 0.0, breakdown: %{}, violations: ["No quality standards defined"]}
  end

  def score_media_file(%__MODULE__{quality_standards: standards}, media_attrs) do
    # Calculate individual component scores
    video_codec_score = score_video_codec(standards, media_attrs)
    audio_codec_score = score_audio_codec(standards, media_attrs)
    audio_channels_score = score_audio_channels(standards, media_attrs)
    resolution_score = score_resolution(standards, media_attrs)
    source_score = score_source(standards, media_attrs)
    file_size_score = score_file_size(standards, media_attrs)
    hdr_score = score_hdr_format(standards, media_attrs)

    # Collect violations
    violations = collect_violations(standards, media_attrs)

    # If there are hard violations, return 0 score
    if violations != [] do
      %{
        score: 0.0,
        breakdown: %{
          video_codec: video_codec_score,
          audio_codec: audio_codec_score,
          audio_channels: audio_channels_score,
          resolution: resolution_score,
          source: source_score,
          file_size: file_size_score,
          hdr: hdr_score
        },
        violations: violations
      }
    else
      # Calculate weighted average
      # Weights sum to 1.0; bitrate terms removed (no real effect on search ranking)
      weights = %{
        video_codec: 0.22,
        audio_codec: 0.16,
        audio_channels: 0.12,
        resolution: 0.24,
        source: 0.12,
        file_size: 0.07,
        hdr: 0.07
      }

      total_score =
        video_codec_score * weights.video_codec +
          audio_codec_score * weights.audio_codec +
          audio_channels_score * weights.audio_channels +
          resolution_score * weights.resolution +
          source_score * weights.source +
          file_size_score * weights.file_size +
          hdr_score * weights.hdr

      %{
        score: Float.round(total_score, 1),
        breakdown: %{
          video_codec: video_codec_score,
          audio_codec: audio_codec_score,
          audio_channels: audio_channels_score,
          resolution: resolution_score,
          source: source_score,
          file_size: file_size_score,
          hdr: hdr_score
        },
        violations: []
      }
    end
  end

  @doc """
  Returns the profile's preferred resolution allow-list from quality_standards,
  accepting atom or string keys. Returns [] when unset.
  """
  def preferred_resolutions(%__MODULE__{quality_standards: standards}) when is_map(standards) do
    Map.get(standards, :preferred_resolutions) || Map.get(standards, "preferred_resolutions") ||
      []
  end

  def preferred_resolutions(_profile), do: []

  @doc """
  The canonical resolution vocabulary, ordered ascending from lowest to highest
  quality.

  This is the single source of truth for resolution ordering. Anything that
  needs to rank resolutions against each other (validation, the ranker's
  preference ordering) must derive from this list rather than keeping its own
  copy, so the two can never drift apart.
  """
  @spec valid_resolutions() :: [String.t()]
  def valid_resolutions, do: @valid_resolutions

  # A profile must specify at least one preferred resolution. With the
  # standalone `qualities` list gone, the allow-list lives entirely in
  # quality_standards.preferred_resolutions.
  defp validate_preferred_resolutions_present(changeset) do
    if changeset |> apply_changes() |> preferred_resolutions() |> Enum.any?() do
      changeset
    else
      add_error(
        changeset,
        :quality_standards,
        "must include at least one preferred resolution"
      )
    end
  end

  # Private validation helpers

  defp validate_video_codecs(changeset, standards) do
    case Map.get(standards, :preferred_video_codecs) do
      nil ->
        changeset

      codecs when is_list(codecs) ->
        invalid_codecs = codecs -- @valid_video_codecs

        if Enum.empty?(invalid_codecs) do
          changeset
        else
          add_error(
            changeset,
            :quality_standards,
            "contains invalid video codecs: #{Enum.join(invalid_codecs, ", ")}. " <>
              "Valid codecs: #{Enum.join(@valid_video_codecs, ", ")}"
          )
        end

      _ ->
        add_error(changeset, :quality_standards, "preferred_video_codecs must be a list")
    end
  end

  defp validate_audio_codecs(changeset, standards) do
    case Map.get(standards, :preferred_audio_codecs) do
      nil ->
        changeset

      codecs when is_list(codecs) ->
        invalid_codecs = codecs -- @valid_audio_codecs

        if Enum.empty?(invalid_codecs) do
          changeset
        else
          add_error(
            changeset,
            :quality_standards,
            "contains invalid audio codecs: #{Enum.join(invalid_codecs, ", ")}. " <>
              "Valid codecs: #{Enum.join(@valid_audio_codecs, ", ")}"
          )
        end

      _ ->
        add_error(changeset, :quality_standards, "preferred_audio_codecs must be a list")
    end
  end

  defp validate_audio_channels(changeset, standards) do
    case Map.get(standards, :preferred_audio_channels) do
      nil ->
        changeset

      channels when is_list(channels) ->
        invalid_channels = channels -- @valid_audio_channels

        if Enum.empty?(invalid_channels) do
          changeset
        else
          add_error(
            changeset,
            :quality_standards,
            "contains invalid audio channels: #{Enum.join(invalid_channels, ", ")}. " <>
              "Valid channels: #{Enum.join(@valid_audio_channels, ", ")}"
          )
        end

      _ ->
        add_error(changeset, :quality_standards, "preferred_audio_channels must be a list")
    end
  end

  defp validate_resolution_ranges(changeset, standards) do
    min_resolution = Map.get(standards, :min_resolution)
    max_resolution = Map.get(standards, :max_resolution)

    changeset =
      if min_resolution && min_resolution not in @valid_resolutions do
        add_error(
          changeset,
          :quality_standards,
          "min_resolution must be one of: #{Enum.join(@valid_resolutions, ", ")}"
        )
      else
        changeset
      end

    changeset =
      if max_resolution && max_resolution not in @valid_resolutions do
        add_error(
          changeset,
          :quality_standards,
          "max_resolution must be one of: #{Enum.join(@valid_resolutions, ", ")}"
        )
      else
        changeset
      end

    # Validate min <= max resolution
    if min_resolution && max_resolution do
      min_index = Enum.find_index(@valid_resolutions, &(&1 == min_resolution))
      max_index = Enum.find_index(@valid_resolutions, &(&1 == max_resolution))

      if min_index && max_index && min_index > max_index do
        add_error(
          changeset,
          :quality_standards,
          "min_resolution (#{min_resolution}) cannot be greater than max_resolution (#{max_resolution})"
        )
      else
        changeset
      end
    else
      changeset
    end
  end

  defp validate_resolutions(changeset, standards) do
    case Map.get(standards, :preferred_resolutions) do
      nil ->
        changeset

      resolutions when is_list(resolutions) ->
        invalid_resolutions = resolutions -- @valid_resolutions

        if Enum.empty?(invalid_resolutions) do
          changeset
        else
          add_error(
            changeset,
            :quality_standards,
            "contains invalid resolutions: #{Enum.join(invalid_resolutions, ", ")}. " <>
              "Valid resolutions: #{Enum.join(@valid_resolutions, ", ")}"
          )
        end

      _ ->
        add_error(changeset, :quality_standards, "preferred_resolutions must be a list")
    end
  end

  defp validate_sources(changeset, standards) do
    case Map.get(standards, :preferred_sources) do
      nil ->
        changeset

      sources when is_list(sources) ->
        invalid_sources = sources -- @valid_sources

        if Enum.empty?(invalid_sources) do
          changeset
        else
          add_error(
            changeset,
            :quality_standards,
            "contains invalid sources: #{Enum.join(invalid_sources, ", ")}. " <>
              "Valid sources: #{Enum.join(@valid_sources, ", ")}"
          )
        end

      _ ->
        add_error(changeset, :quality_standards, "preferred_sources must be a list")
    end
  end

  defp validate_media_type_sizes(changeset, standards) do
    # Validate movie sizes
    movie_min = Map.get(standards, :movie_min_size_mb)
    movie_max = Map.get(standards, :movie_max_size_mb)

    changeset =
      if movie_min && !is_integer(movie_min) do
        add_error(changeset, :quality_standards, "movie_min_size_mb must be an integer")
      else
        changeset
      end

    changeset =
      if movie_max && !is_integer(movie_max) do
        add_error(changeset, :quality_standards, "movie_max_size_mb must be an integer")
      else
        changeset
      end

    changeset =
      if movie_min && movie_max && movie_min > movie_max do
        add_error(
          changeset,
          :quality_standards,
          "movie_min_size_mb cannot be greater than movie_max_size_mb"
        )
      else
        changeset
      end

    # Validate episode sizes
    episode_min = Map.get(standards, :episode_min_size_mb)
    episode_max = Map.get(standards, :episode_max_size_mb)

    changeset =
      if episode_min && !is_integer(episode_min) do
        add_error(changeset, :quality_standards, "episode_min_size_mb must be an integer")
      else
        changeset
      end

    changeset =
      if episode_max && !is_integer(episode_max) do
        add_error(changeset, :quality_standards, "episode_max_size_mb must be an integer")
      else
        changeset
      end

    if episode_min && episode_max && episode_min > episode_max do
      add_error(
        changeset,
        :quality_standards,
        "episode_min_size_mb cannot be greater than episode_max_size_mb"
      )
    else
      changeset
    end
  end

  defp validate_hdr_formats(changeset, standards) do
    hdr_formats = Map.get(standards, :hdr_formats)
    require_hdr = Map.get(standards, :require_hdr)

    changeset =
      case hdr_formats do
        nil ->
          changeset

        formats when is_list(formats) ->
          invalid_formats = formats -- @valid_hdr_formats

          if Enum.empty?(invalid_formats) do
            changeset
          else
            add_error(
              changeset,
              :quality_standards,
              "contains invalid HDR formats: #{Enum.join(invalid_formats, ", ")}. " <>
                "Valid formats: #{Enum.join(@valid_hdr_formats, ", ")}"
            )
          end

        _ ->
          add_error(changeset, :quality_standards, "hdr_formats must be a list")
      end

    if require_hdr && !is_boolean(require_hdr) do
      add_error(changeset, :quality_standards, "require_hdr must be a boolean")
    else
      changeset
    end
  end

  defp validate_min_ratio(changeset, standards) do
    case Map.get(standards, :min_ratio) || Map.get(standards, "min_ratio") do
      nil ->
        changeset

      value when is_number(value) and value >= 0 ->
        changeset

      _ ->
        add_error(changeset, :quality_standards, "min_ratio must be a non-negative number")
    end
  end

  # Quality scoring helpers

  defp score_video_codec(standards, %{video_codec: codec}) when is_binary(codec) do
    case Map.get(standards, :preferred_video_codecs) do
      nil ->
        100.0

      codecs when is_list(codecs) ->
        score_from_preference_list(codec, codecs)

      _ ->
        100.0
    end
  end

  defp score_video_codec(_standards, _media_attrs), do: 50.0

  defp score_audio_codec(standards, %{audio_codec: codec}) when is_binary(codec) do
    case Map.get(standards, :preferred_audio_codecs) do
      nil ->
        100.0

      codecs when is_list(codecs) ->
        score_from_preference_list(codec, codecs)

      _ ->
        100.0
    end
  end

  defp score_audio_codec(_standards, _media_attrs), do: 50.0

  defp score_audio_channels(standards, %{audio_channels: channels}) when is_binary(channels) do
    case Map.get(standards, :preferred_audio_channels) do
      nil ->
        100.0

      channel_list when is_list(channel_list) ->
        score_from_preference_list(channels, channel_list)

      _ ->
        100.0
    end
  end

  defp score_audio_channels(_standards, _media_attrs), do: 50.0

  defp score_resolution(standards, %{resolution: resolution}) when is_binary(resolution) do
    min_resolution = Map.get(standards, :min_resolution)
    max_resolution = Map.get(standards, :max_resolution)
    preferred_resolutions = Map.get(standards, :preferred_resolutions, [])

    # Check if within range first
    score =
      cond do
        # Check preferred list
        resolution in preferred_resolutions ->
          100.0

        # Check if within min/max range
        is_within_resolution_range?(resolution, min_resolution, max_resolution) ->
          75.0

        true ->
          25.0
      end

    score
  end

  defp score_resolution(_standards, _media_attrs), do: 50.0

  defp score_source(standards, %{source: source}) when is_binary(source) do
    case Map.get(standards, :preferred_sources) do
      nil ->
        100.0

      sources when is_list(sources) ->
        score_from_preference_list(source, sources)

      _ ->
        100.0
    end
  end

  defp score_source(_standards, _media_attrs), do: 50.0

  defp score_file_size(standards, %{file_size_mb: size, media_type: :movie})
       when is_number(size) do
    min_size = Map.get(standards, :movie_min_size_mb)
    max_size = Map.get(standards, :movie_max_size_mb)

    score_from_range(size, min_size, max_size, nil)
  end

  defp score_file_size(standards, %{file_size_mb: size, media_type: :episode})
       when is_number(size) do
    min_size = Map.get(standards, :episode_min_size_mb)
    max_size = Map.get(standards, :episode_max_size_mb)

    score_from_range(size, min_size, max_size, nil)
  end

  defp score_file_size(_standards, _media_attrs), do: 50.0

  defp score_hdr_format(standards, %{hdr_format: format}) when is_binary(format) do
    case Map.get(standards, :hdr_formats) do
      nil ->
        100.0

      formats when is_list(formats) ->
        score_from_preference_list(format, formats)

      _ ->
        100.0
    end
  end

  defp score_hdr_format(_standards, _media_attrs), do: 50.0

  defp collect_violations(standards, media_attrs) do
    violations = []

    # Check HDR requirement
    violations =
      if Map.get(standards, :require_hdr) == true && !Map.has_key?(media_attrs, :hdr_format) do
        ["HDR is required but file does not have HDR" | violations]
      else
        violations
      end

    # Check resolution range violations
    violations =
      case {Map.get(standards, :min_resolution), Map.get(media_attrs, :resolution)} do
        {min_res, res} when is_binary(min_res) and is_binary(res) ->
          if is_below_resolution?(res, min_res) do
            ["Resolution #{res} is below minimum #{min_res}" | violations]
          else
            violations
          end

        _ ->
          violations
      end

    violations =
      case {Map.get(standards, :max_resolution), Map.get(media_attrs, :resolution)} do
        {max_res, res} when is_binary(max_res) and is_binary(res) ->
          if is_above_resolution?(res, max_res) do
            ["Resolution #{res} is above maximum #{max_res}" | violations]
          else
            violations
          end

        _ ->
          violations
      end

    violations
  end

  # Scores a value based on its position in a preference list
  # First item = 100, last item = 60, not in list = 25
  defp score_from_preference_list(value, preference_list) do
    case Enum.find_index(preference_list, &(&1 == value)) do
      nil ->
        25.0

      index ->
        # Linear decay from 100 to 60
        max_score = 100.0
        min_score = 60.0
        list_size = length(preference_list)

        if list_size == 1 do
          max_score
        else
          max_score - index * (max_score - min_score) / (list_size - 1)
        end
    end
  end

  # Scores a value based on its position within a range
  defp score_from_range(value, min_val, max_val, preferred_val) do
    cond do
      # If we have a preferred value and match it, perfect score
      preferred_val && value == preferred_val ->
        100.0

      # If we have a preferred value and are close to it (within 10%), high score
      preferred_val && abs(value - preferred_val) / preferred_val <= 0.10 ->
        95.0

      # If within min/max range, decent score
      min_val && max_val && value >= min_val && value <= max_val ->
        75.0

      # If only min is set and above it
      min_val && !max_val && value >= min_val ->
        75.0

      # If only max is set and below it
      !min_val && max_val && value <= max_val ->
        75.0

      # If no constraints are set
      !min_val && !max_val ->
        100.0

      # Otherwise, below range or above range
      true ->
        25.0
    end
  end

  defp is_within_resolution_range?(_resolution, nil, nil), do: true

  defp is_within_resolution_range?(resolution, min_res, max_res) do
    res_index = Enum.find_index(@valid_resolutions, &(&1 == resolution))
    min_index = min_res && Enum.find_index(@valid_resolutions, &(&1 == min_res))
    max_index = max_res && Enum.find_index(@valid_resolutions, &(&1 == max_res))

    cond do
      !res_index -> false
      min_index && res_index < min_index -> false
      max_index && res_index > max_index -> false
      true -> true
    end
  end

  defp is_below_resolution?(resolution, min_resolution) do
    res_index = Enum.find_index(@valid_resolutions, &(&1 == resolution))
    min_index = Enum.find_index(@valid_resolutions, &(&1 == min_resolution))

    res_index && min_index && res_index < min_index
  end

  defp is_above_resolution?(resolution, max_resolution) do
    res_index = Enum.find_index(@valid_resolutions, &(&1 == resolution))
    max_index = Enum.find_index(@valid_resolutions, &(&1 == max_resolution))

    res_index && max_index && res_index > max_index
  end
end
