defmodule Mydia.Library.MatchCandidate do
  @moduledoc """
  A cached metadata match for a `MediaFile` that has not been linked yet.

  Candidates are what makes a stopped import resumable without redoing work:
  a file holding a candidate is skipped by the matching phase of any later run,
  and the review inbox renders from these rows rather than hitting the relay.

  A row with no `provider_id` records a match failure. That is a meaningful
  state, not a broken one, and it is what the inbox shows as unidentified.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Mydia.Library.MediaFile

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: binary(),
          media_file_id: binary(),
          rank: integer(),
          provider_type: String.t() | nil,
          provider_id: String.t() | nil,
          title: String.t() | nil,
          year: integer() | nil,
          media_type: String.t() | nil,
          confidence: float() | nil,
          parsed_info: map() | nil,
          attempts: integer(),
          last_error: String.t() | nil,
          next_retry_at: DateTime.t() | nil
        }

  schema "media_file_match_candidates" do
    field :rank, :integer, default: 0
    field :provider_type, :string
    field :provider_id, :string
    field :title, :string
    field :year, :integer
    field :media_type, :string
    field :confidence, :float
    field :parsed_info, Mydia.Settings.JsonMapType
    field :attempts, :integer, default: 0
    field :last_error, :string
    field :next_retry_at, :utc_datetime

    belongs_to :media_file, MediaFile

    timestamps(type: :utc_datetime)
  end

  @castable ~w(media_file_id rank provider_type provider_id title year
               media_type confidence parsed_info attempts last_error
               next_retry_at)a

  @doc """
  Builds a changeset for a match candidate.
  """
  def changeset(candidate, attrs) do
    candidate
    |> cast(attrs, @castable)
    |> validate_required([:media_file_id, :rank])
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> foreign_key_constraint(:media_file_id)
    |> unique_constraint([:media_file_id, :rank])
  end

  @doc """
  Builds the match map `FileIngest.ingest/3` expects from a stored candidate.

  The single conversion, shared by `Jobs.ApplyImportGroups` (which layers its
  group-level fallbacks on top) and `Library.OrphanReenricher` (which uses it
  as is). Both traps below are why this is one function rather than two.

  `provider_type` is a free-text column with no inclusion validation, so
  `String.to_existing_atom/1` on it could raise for a value this VM has never
  interned. Only the two providers this ever legitimately holds are mapped;
  anything else takes the same default a nil would.

  `parsed_info` round-trips through JSON (`Mydia.Settings.JsonMapType`), so its
  keys and its "type" value are strings.
  `MetadataEnricher.determine_media_type/1` pattern-matches
  `%{parsed_info: %{type: :movie}}` with atom keys and an atom value, so the
  stored shape matches neither clause and silently falls through to the movie
  default for every file. This rebuilds the atom-keyed shape it expects.
  """
  @spec to_match(t()) :: map()
  def to_match(%__MODULE__{} = candidate) do
    %{
      provider_id: candidate.provider_id,
      provider_type: known_provider(candidate.provider_type) || :tvdb,
      title: candidate.title,
      year: candidate.year,
      match_confidence: candidate.confidence || 1.0,
      # A cached candidate was written from a provider lookup, never from the
      # local database, so auto-import accounting counts it as external.
      from_local_db: false,
      parsed_info: parsed_info(candidate)
    }
  end

  @doc "Maps the two provider strings this column legitimately holds, nil otherwise."
  @spec known_provider(String.t() | nil) :: :tmdb | :tvdb | nil
  def known_provider("tmdb"), do: :tmdb
  def known_provider("tvdb"), do: :tvdb
  def known_provider(_other), do: nil

  @doc "Rebuilds the atom-keyed parsed_info shape from the stored JSON map."
  @spec parsed_info(t()) :: %{
          type: :movie | :tv_show,
          season: integer() | nil,
          episodes: [integer()]
        }
  def parsed_info(%__MODULE__{} = candidate) do
    stored = candidate.parsed_info || %{}

    %{
      type: media_type_atom(candidate.media_type),
      season: Map.get(stored, "season"),
      episodes: Map.get(stored, "episodes") || []
    }
  end

  @doc "The two media types this column holds, defaulting to movie."
  @spec media_type_atom(String.t() | nil) :: :movie | :tv_show
  def media_type_atom("tv_show"), do: :tv_show
  def media_type_atom(_other), do: :movie
end
