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
               season_span status decided_at)a

  @doc "Builds a changeset for an import group."
  def changeset(group, attrs) do
    group
    |> cast(attrs, @castable)
    |> put_anchor_path(attrs)
    |> cast_season_span()
    # `:anchor_path` is deliberately NOT in this list. `PathAnchor.anchor_for/2`
    # returns `anchor_path: ""` for a file that sits directly at the library
    # root with no per-title folder -- an ordinary, common layout for a movie
    # library, not an edge case -- and `display_title/1` in `ImportGroups` has
    # a dedicated "Loose files" clause for exactly that group. Requiring it
    # here rejected every such group with "can't be blank", so
    # `upsert_for_library/2` crashed instead of grouping anything -- which
    # would have taken the backfill migration and every subsequent import run
    # down with it for any movies stored loose. The column itself is still
    # `null: false` at the DB level (see the `create_import_groups`
    # migration), so a genuinely missing value is still refused; only the
    # empty string, which is always explicitly supplied by `write_group/4`, is
    # allowed through here.
    |> validate_required([:library_path_id, :cluster_key, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:min_confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> foreign_key_constraint(:library_path_id)
    |> unique_constraint([:library_path_id, :cluster_key], error_key: :cluster_key)
  end

  # `cast/3` treats an empty string as "field not provided" for every string
  # column (its `:empty_values` default is `[""]`), so `anchor_path: ""` --
  # the value `write_group/4` always supplies for a "Loose files" root group
  # -- was silently dropped from `changes` instead of being cast to the
  # literal empty string. A freshly-built `%ImportGroup{}` has no default for
  # that field, so the insert sent SQL NULL straight into a `null: false`
  # column and raised a raw adapter error instead of the friendly
  # `validate_required/3` message this changeset was actually relying on.
  # Applied after `cast/3` and scoped to just this one field -- widening
  # `cast/3`'s own `:empty_values` option would change every other string
  # column's blank-handling too, which nothing here needs.
  defp put_anchor_path(changeset, %{anchor_path: value}),
    do: put_change(changeset, :anchor_path, value)

  defp put_anchor_path(changeset, _attrs), do: changeset

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

  defp cast_season_span(changeset) do
    case get_change(changeset, :season_span) do
      nil ->
        changeset

      list ->
        put_change(changeset, :season_span_json, Jason.encode!(Enum.sort(Enum.uniq(list))))
    end
  end
end
