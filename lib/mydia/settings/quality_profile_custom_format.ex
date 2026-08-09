defmodule Mydia.Settings.QualityProfileCustomFormat do
  @moduledoc """
  What a single custom format means to a single quality profile.

  `format_slug` is deliberately not a foreign key. A built-in format has no row
  in `custom_formats` until someone overrides it, so an FK would make it
  impossible to score a built-in. A slug that resolves to nothing is skipped
  and logged at search time; see `Mydia.Settings.CustomFormats.resolve_for_profile/1`.

  `score` and `reject` are separate columns. `reject` wins when both are set.
  The UI presents them as one mutually exclusive control, so the combination is
  not reachable through normal use, but the schema tolerates it rather than
  failing.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @score_limit 10_000

  @type t :: %__MODULE__{
          id: binary(),
          quality_profile_id: binary() | nil,
          format_slug: String.t() | nil,
          score: integer(),
          reject: boolean()
        }

  schema "quality_profile_custom_formats" do
    field :quality_profile_id, :binary_id
    field :format_slug, :string
    field :score, :integer, default: 0
    field :reject, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [:quality_profile_id, :format_slug, :score, :reject])
    |> validate_required([:quality_profile_id, :format_slug])
    |> validate_number(:score,
      greater_than_or_equal_to: -@score_limit,
      less_than_or_equal_to: @score_limit
    )
    |> unique_constraint([:quality_profile_id, :format_slug])
  end

  @doc "The inclusive bound on an assignment score."
  @spec score_limit() :: pos_integer()
  def score_limit, do: @score_limit
end
