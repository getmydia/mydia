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
end
