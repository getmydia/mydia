defmodule Mydia.Library.MediaSegment do
  @moduledoc """
  A detected region of a media file that a viewer may want to skip.

  Exactly one segment per `type` per file. `source` records how the segment was
  found so the operator can tell a chapter-marker hit (always trustworthy) from
  a fingerprint consensus (scored by `confidence`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @types ~w(intro credits)
  @sources ~w(chapters fingerprint)

  @type t :: %__MODULE__{
          id: binary(),
          media_file_id: binary(),
          type: String.t(),
          start_ms: integer(),
          end_ms: integer(),
          source: String.t(),
          confidence: float(),
          media_file: Mydia.Library.MediaFile.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "media_segments" do
    field :type, :string
    field :start_ms, :integer
    field :end_ms, :integer
    field :source, :string
    field :confidence, :float

    belongs_to :media_file, Mydia.Library.MediaFile

    timestamps(type: :utc_datetime)
  end

  @doc "Returns the valid segment types."
  @spec types() :: [String.t()]
  def types, do: @types

  @doc "Returns the valid segment sources."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @doc """
  Changeset for creating or updating a segment.
  """
  def changeset(segment, attrs) do
    segment
    |> cast(attrs, [:media_file_id, :type, :start_ms, :end_ms, :source, :confidence])
    |> validate_required([:media_file_id, :type, :start_ms, :end_ms, :source, :confidence])
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:source, @sources)
    |> validate_number(:start_ms, greater_than_or_equal_to: 0)
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_end_after_start()
    |> foreign_key_constraint(:media_file_id)
    |> unique_constraint([:media_file_id, :type],
      name: :media_segments_media_file_id_type_index
    )
  end

  defp validate_end_after_start(changeset) do
    start_ms = get_field(changeset, :start_ms)
    end_ms = get_field(changeset, :end_ms)

    if is_integer(start_ms) and is_integer(end_ms) and end_ms <= start_ms do
      add_error(changeset, :end_ms, "must be greater than start_ms")
    else
      changeset
    end
  end
end
