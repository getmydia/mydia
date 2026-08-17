defmodule Mydia.Library.ImportGroup do
  @moduledoc """
  A folder cluster awaiting an import decision.

  One row per anchor folder, computed by `Mydia.Library.PathAnchor` from paths
  alone. This is the unit the review page renders and the unit a human accepts,
  which is what turns a library's worth of unresolved files into a page of
  decisions.

  `cluster_key` is unique per library path, so a rescan that recomputes the same
  anchor lands on the existing row and keeps its decision. That is the whole
  rescan-stability mechanism; there is no separate alias table.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Mydia.Library.ImportRun
  alias Mydia.Settings.LibraryPath

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending accepted applied ignored)

  @type t :: %__MODULE__{
          id: binary(),
          library_path_id: binary(),
          import_run_id: binary() | nil,
          anchor_path: String.t(),
          cluster_key: String.t(),
          display_title: String.t() | nil,
          file_count: non_neg_integer(),
          unresolved_count: non_neg_integer(),
          numbered_count: non_neg_integer(),
          media_type: String.t() | nil,
          provider_type: String.t() | nil,
          provider_id: String.t() | nil,
          suggested_title: String.t() | nil,
          suggested_year: integer() | nil,
          min_confidence: float() | nil,
          evidence: map() | nil,
          season_span: [integer()] | nil,
          status: String.t(),
          decided_at: DateTime.t() | nil
        }

  schema "import_groups" do
    field :anchor_path, :string
    field :cluster_key, :string
    field :display_title, :string

    field :file_count, :integer, default: 0
    field :unresolved_count, :integer, default: 0
    field :numbered_count, :integer, default: 0

    field :media_type, :string
    field :provider_type, :string
    field :provider_id, :string
    field :suggested_title, :string
    field :suggested_year, :integer
    field :min_confidence, :float
    field :evidence, Mydia.Settings.JsonMapType
    field :season_span, {:array, :integer}, virtual: true
    field :season_span_json, :string, source: :season_span

    field :status, :string, default: "pending"
    field :decided_at, :utc_datetime

    # Plain belongs_to, matching MediaFile. @foreign_key_type :binary_id above
    # already makes these binary ids, and belongs_to defines the *_id field, so
    # declaring it separately would be a duplicate-field compile error.
    belongs_to :library_path, LibraryPath
    belongs_to :import_run, ImportRun

    timestamps(type: :utc_datetime)
  end

  @castable ~w(library_path_id import_run_id anchor_path cluster_key display_title
               file_count unresolved_count numbered_count media_type provider_type
               provider_id suggested_title suggested_year min_confidence evidence
               status decided_at)a

  @doc "Builds a changeset for an import group."
  def changeset(group, attrs) do
    group
    |> cast(attrs, @castable)
    |> cast_season_span(attrs)
    |> validate_required([:library_path_id, :anchor_path, :cluster_key, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:min_confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> foreign_key_constraint(:library_path_id)
    |> unique_constraint([:library_path_id, :cluster_key], error_key: :cluster_key)
  end

  @doc "The valid status values."
  def statuses, do: @statuses

  @doc "Decodes the stored season span into a sorted integer list."
  @spec season_span(t()) :: [integer()]
  def season_span(%__MODULE__{season_span_json: nil}), do: []

  def season_span(%__MODULE__{season_span_json: json}) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp cast_season_span(changeset, attrs) do
    case attrs[:season_span] || attrs["season_span"] do
      nil ->
        changeset

      list when is_list(list) ->
        put_change(changeset, :season_span_json, Jason.encode!(Enum.sort(Enum.uniq(list))))

      _ ->
        changeset
    end
  end
end
