defmodule Mydia.Settings.CustomFormat do
  @moduledoc """
  A named set of release-title regexes.

  Rows here are either operator-created formats or overrides of a built-in
  defined in `Mydia.Settings.CustomFormats.Manifest`. An override shares the
  built-in's `slug` and sets `overrides_builtin: true`; deleting it restores
  the shipped definition.

  Per-profile meaning does not live here. A format's score and reject flag are
  properties of the profile-to-format pair, held in
  `Mydia.Settings.QualityProfileCustomFormat`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Mydia.Settings.CustomFormats.Matcher

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @max_pattern_length 500
  @max_patterns 20

  @type t :: %__MODULE__{
          id: binary(),
          slug: String.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          patterns: [String.t()],
          overrides_builtin: boolean(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "custom_formats" do
    field :slug, :string
    field :name, :string
    field :description, :string
    field :patterns, {:array, :string}, default: []
    field :overrides_builtin, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a format.

  Every pattern must compile, because an uncompilable pattern would otherwise
  fail at search time where there is no one to show the error to.
  """
  def changeset(custom_format, attrs) do
    custom_format
    |> cast(attrs, [:slug, :name, :description, :patterns, :overrides_builtin])
    |> validate_required([:slug, :name])
    |> unique_constraint(:slug)
    |> validate_patterns()
  end

  @doc """
  Converts a display name into a url-safe slug.

  Slugs are assigned once at creation and never change on rename, so a
  profile's scores survive renaming a format.
  """
  @spec slugify(String.t()) :: String.t()
  def slugify(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  @doc "The maximum number of patterns a single format may carry."
  @spec max_patterns() :: pos_integer()
  def max_patterns, do: @max_patterns

  @doc "The maximum length of a single pattern, in characters."
  @spec max_pattern_length() :: pos_integer()
  def max_pattern_length, do: @max_pattern_length

  defp validate_patterns(changeset) do
    patterns = get_field(changeset, :patterns) || []

    cond do
      patterns == [] ->
        add_error(changeset, :patterns, "must include at least one pattern")

      length(patterns) > @max_patterns ->
        add_error(changeset, :patterns, "cannot exceed #{@max_patterns} patterns")

      Enum.any?(patterns, &(String.length(&1) > @max_pattern_length)) ->
        add_error(
          changeset,
          :patterns,
          "each pattern must be #{@max_pattern_length} characters or fewer"
        )

      true ->
        validate_pattern_syntax(changeset, patterns)
    end
  end

  defp validate_pattern_syntax(changeset, patterns) do
    Enum.reduce(patterns, changeset, fn pattern, acc ->
      case Matcher.compile_pattern(pattern) do
        {:ok, _} -> acc
        {:error, message} -> add_error(acc, :patterns, "#{pattern}: #{message}")
      end
    end)
  end
end
