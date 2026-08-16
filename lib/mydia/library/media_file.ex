defmodule Mydia.Library.MediaFile do
  @moduledoc """
  Schema for media files (multiple versions support).
  """
  use Ecto.Schema
  import Ecto.Changeset
  require Logger

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: binary(),
          path: String.t() | nil,
          size: integer() | nil,
          resolution: String.t() | nil,
          codec: String.t() | nil,
          hdr_format: String.t() | nil,
          audio_codec: String.t() | nil,
          bitrate: integer() | nil,
          verified_at: DateTime.t() | nil,
          analyzed_at: DateTime.t() | nil,
          analysis_attempts: integer(),
          last_analysis_error: String.t() | nil,
          metadata: Mydia.Library.Structs.FileMetadata.t(),
          cover_blob: String.t() | nil,
          sprite_blob: String.t() | nil,
          vtt_blob: String.t() | nil,
          preview_blob: String.t() | nil,
          phash: String.t() | nil,
          segment_analysis_state: String.t(),
          segments_analyzed_at: DateTime.t() | nil,
          segment_analysis_attempts: integer(),
          last_segment_analysis_error: String.t() | nil,
          fingerprint_blob: String.t() | nil,
          generated_at: DateTime.t() | nil,
          trashed_at: DateTime.t() | nil,
          relative_path: String.t() | nil,
          supersedes_media_file_id: binary() | nil,
          library_path: Mydia.Settings.LibraryPath.t() | Ecto.Association.NotLoaded.t(),
          media_item: Mydia.Media.MediaItem.t() | Ecto.Association.NotLoaded.t(),
          episode: Mydia.Media.Episode.t() | nil | Ecto.Association.NotLoaded.t(),
          quality_profile:
            Mydia.Settings.QualityProfile.t() | nil | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "media_files" do
    field :path, :string
    field :size, :integer
    field :resolution, :string
    field :codec, :string
    field :hdr_format, :string
    field :audio_codec, :string
    field :bitrate, :integer
    field :verified_at, :utc_datetime
    field :analyzed_at, :utc_datetime
    field :analysis_attempts, :integer, default: 0
    field :last_analysis_error, :string
    field :metadata, Mydia.Library.FileMetadataType

    # Generated media content references (MD5 checksums as storage keys)
    field :cover_blob, :string
    field :sprite_blob, :string
    field :vtt_blob, :string
    field :preview_blob, :string
    field :phash, :string
    field :generated_at, :utc_datetime

    # Intro/credits segment detection state, mirroring the analyzed_at /
    # analysis_attempts / last_analysis_error triple used by FileAnalysis.
    field :segment_analysis_state, :string, default: "pending"
    field :segments_analyzed_at, :utc_datetime
    field :segment_analysis_attempts, :integer, default: 0
    field :last_segment_analysis_error, :string
    field :fingerprint_blob, :string

    # Soft-delete: files missing from disk are trashed for 30 days before permanent deletion
    field :trashed_at, :utc_datetime

    # Relative path storage (Phase 1)
    field :relative_path, :string
    belongs_to :library_path, Mydia.Settings.LibraryPath

    belongs_to :media_item, Mydia.Media.MediaItem
    belongs_to :episode, Mydia.Media.Episode
    belongs_to :quality_profile, Mydia.Settings.QualityProfile
    has_many :segments, Mydia.Library.MediaSegment
    belongs_to :supersedes_media_file, __MODULE__, foreign_key: :supersedes_media_file_id

    timestamps(type: :utc_datetime)
  end

  @doc """
  Resolves the absolute file path from relative_path and library_path.

  The library_path association must be preloaded.

  ## Examples

      iex> file = %MediaFile{relative_path: "Movie.mkv", library_path: %LibraryPath{path: "/movies"}}
      iex> MediaFile.absolute_path(file)
      "/movies/Movie.mkv"

      iex> file = %MediaFile{relative_path: "Movie.mkv", library_path: nil}
      iex> MediaFile.absolute_path(file)
      nil
  """
  def absolute_path(%__MODULE__{
        relative_path: relative_path,
        library_path: %Mydia.Settings.LibraryPath{path: path}
      })
      when not is_nil(relative_path) and not is_nil(path) do
    Path.join(path, relative_path)
  end

  def absolute_path(%__MODULE__{id: id, library_path: %Ecto.Association.NotLoaded{}}) do
    Logger.warning(
      "MediaFile.absolute_path/1 called with an unloaded library_path association",
      media_file_id: id
    )

    nil
  end

  def absolute_path(%__MODULE__{}), do: nil

  @doc """
  Best path to show an operator, or nil when the file has no location at all.

  `absolute_path/1` is the answer whenever the library_path is preloaded and
  set. It falls back to the relative path so an unloaded association degrades
  into a partial answer instead of nothing, and then to the legacy `path`
  column as a last resort.

  That last fallback looks dead — every row on a current install carries
  `path: nil` — but `populate_media_file_relative_paths` skips files sitting
  outside every configured library path, leaving them with no relative_path and
  no library_path_id. On an install that upgraded from a version which still
  wrote `path`, that column is the only location such a row has left.

  ## Examples

      iex> file = %MediaFile{relative_path: "Movie.mkv", library_path: %LibraryPath{path: "/movies"}}
      iex> MediaFile.display_path(file)
      "/movies/Movie.mkv"

      iex> file = %MediaFile{relative_path: "Movie.mkv", library_path: nil}
      iex> MediaFile.display_path(file)
      "Movie.mkv"
  """
  @spec display_path(t()) :: String.t() | nil
  def display_path(%__MODULE__{} = media_file) do
    absolute_path(media_file) || media_file.relative_path || media_file.path
  end

  @doc """
  File name to show an operator, never nil.

  Templates render this directly, so it must not raise for a file whose
  location cannot be resolved. `Path.basename/1` raises on nil, which is how a
  single unresolvable file used to take down the whole LiveView.
  """
  @spec display_name(t()) :: String.t()
  def display_name(%__MODULE__{} = media_file) do
    case display_path(media_file) do
      nil -> "Unknown file"
      path -> Path.basename(path)
    end
  end

  @doc """
  Returns true when a media item / episode is compatible with a library path type.

  Shared rule behind both the changeset-level validation and pre-flight checks
  (e.g. download re-match), so the two cannot drift. `media_item_type` is the
  item's `type` ("movie" / "tv_show") or nil; `has_episode?` is whether an
  `episode_id` is being set. `:mixed` accepts everything; movies are rejected
  from `:series` paths and episodes from `:movies` paths.
  """
  @spec library_type_compatible?(atom(), String.t() | nil, boolean()) :: boolean()
  def library_type_compatible?(:mixed, _media_item_type, _has_episode?), do: true
  def library_type_compatible?(:movies, _media_item_type, true), do: false
  def library_type_compatible?(:series, "movie", _has_episode?), do: false
  def library_type_compatible?(_library_type, _media_item_type, _has_episode?), do: true

  @doc """
  Changeset for creating or updating a media file.
  """
  def changeset(media_file, attrs) do
    media_file
    |> cast(attrs, [
      :media_item_id,
      :episode_id,
      :quality_profile_id,
      :path,
      :relative_path,
      :library_path_id,
      :size,
      :resolution,
      :codec,
      :hdr_format,
      :audio_codec,
      :bitrate,
      :verified_at,
      :analyzed_at,
      :analysis_attempts,
      :last_analysis_error,
      :metadata,
      :cover_blob,
      :sprite_blob,
      :vtt_blob,
      :preview_blob,
      :phash,
      :segment_analysis_state,
      :segments_analyzed_at,
      :segment_analysis_attempts,
      :last_segment_analysis_error,
      :fingerprint_blob,
      :generated_at,
      :trashed_at,
      :supersedes_media_file_id
    ])
    |> validate_required([:relative_path, :library_path_id])
    |> validate_one_parent()
    |> validate_library_type_compatibility()
    |> validate_number(:size, greater_than: 0)
    |> validate_number(:bitrate, greater_than: 0)
    |> check_constraint(:media_item_id,
      name: :media_files_parent_check,
      message: "cannot set both media_item_id and episode_id"
    )
    |> foreign_key_constraint(:media_item_id)
    |> foreign_key_constraint(:episode_id)
    |> foreign_key_constraint(:quality_profile_id)
    |> foreign_key_constraint(:library_path_id)
    |> foreign_key_constraint(:supersedes_media_file_id)
  end

  @doc """
  Changeset for creating a media file during library scanning.
  Parent association (media_item_id or episode_id) is optional during initial creation
  and will be set later during metadata enrichment.
  """
  def scan_changeset(media_file, attrs) do
    media_file
    |> cast(attrs, [
      :media_item_id,
      :episode_id,
      :quality_profile_id,
      :relative_path,
      :library_path_id,
      :size,
      :resolution,
      :codec,
      :hdr_format,
      :audio_codec,
      :bitrate,
      :verified_at,
      :analyzed_at,
      :analysis_attempts,
      :last_analysis_error,
      :metadata,
      :cover_blob,
      :sprite_blob,
      :vtt_blob,
      :preview_blob,
      :phash,
      :segment_analysis_state,
      :segments_analyzed_at,
      :segment_analysis_attempts,
      :last_segment_analysis_error,
      :fingerprint_blob,
      :generated_at,
      :trashed_at
    ])
    |> validate_required([:relative_path, :library_path_id])
    |> validate_parent_exclusivity()
    |> validate_library_type_compatibility()
    |> validate_number(:size, greater_than: 0)
    |> validate_number(:bitrate, greater_than: 0)
    |> check_constraint(:media_item_id,
      name: :media_files_parent_check,
      message: "cannot set both media_item_id and episode_id"
    )
    |> foreign_key_constraint(:media_item_id)
    |> foreign_key_constraint(:episode_id)
    |> foreign_key_constraint(:quality_profile_id)
    |> foreign_key_constraint(:library_path_id)
  end

  # Ensure either media_item_id or episode_id is set, but not both
  defp validate_one_parent(changeset) do
    media_item_id = get_field(changeset, :media_item_id)
    episode_id = get_field(changeset, :episode_id)

    cond do
      is_nil(media_item_id) and is_nil(episode_id) ->
        add_error(changeset, :media_item_id, "either media_item_id or episode_id must be set")

      not is_nil(media_item_id) and not is_nil(episode_id) ->
        add_error(changeset, :media_item_id, "cannot set both media_item_id and episode_id")

      true ->
        changeset
    end
  end

  # Ensure both media_item_id and episode_id are not set at the same time
  # (allows both to be nil for orphaned files during scanning)
  defp validate_parent_exclusivity(changeset) do
    media_item_id = get_field(changeset, :media_item_id)
    episode_id = get_field(changeset, :episode_id)

    if not is_nil(media_item_id) and not is_nil(episode_id) do
      add_error(changeset, :media_item_id, "cannot set both media_item_id and episode_id")
    else
      changeset
    end
  end

  # Validates that the media type is compatible with the library path type
  defp validate_library_type_compatibility(changeset) do
    media_item_id = get_field(changeset, :media_item_id)
    episode_id = get_field(changeset, :episode_id)
    library_path_id = get_field(changeset, :library_path_id)

    # Skip validation if library_path_id is missing (will be caught by validate_required)
    if is_nil(library_path_id) do
      changeset
    else
      # Validate media type compatibility. Only validate if a parent association
      # is set (orphaned files are allowed).
      if is_nil(media_item_id) and is_nil(episode_id) do
        changeset
      else
        validate_media_type_against_library_path_id(
          changeset,
          library_path_id,
          media_item_id,
          episode_id
        )
      end
    end
  end

  defp validate_media_type_against_library_path_id(
         changeset,
         library_path_id,
         media_item_id,
         episode_id
       ) do
    case Mydia.Repo.get(Mydia.Settings.LibraryPath, library_path_id) do
      nil ->
        # Library path not found, let foreign key constraint handle it
        changeset

      library_path ->
        media_item_type = media_item_id && get_media_type_for_item(media_item_id)

        if library_type_compatible?(library_path.type, media_item_type, not is_nil(episode_id)) do
          changeset
        else
          cond do
            # Movie in :series library
            not is_nil(media_item_id) and library_path.type == :series ->
              add_error(
                changeset,
                :media_item_id,
                "cannot add movies to a library path configured for TV series only (path: #{library_path.path})"
              )

            # TV episode in :movies library
            not is_nil(episode_id) and library_path.type == :movies ->
              add_error(
                changeset,
                :episode_id,
                "cannot add TV episodes to a library path configured for movies only (path: #{library_path.path})"
              )

            true ->
              changeset
          end
        end
    end
  end

  # Gets the media type (movie or tv_show) for a media item by ID
  defp get_media_type_for_item(media_item_id) do
    case Mydia.Repo.get(Mydia.Media.MediaItem, media_item_id) do
      nil -> nil
      media_item -> media_item.type
    end
  end
end
