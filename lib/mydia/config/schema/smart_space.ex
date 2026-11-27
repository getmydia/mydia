defmodule Mydia.Config.Schema.SmartSpace do
  @moduledoc """
  The `smart_space` section of `Mydia.Config.Schema`: automatic trashing of
  watched TV.

  Usernames in `selected_users` are not checked here, because the config
  schema runs before and independent of the Repo. Resolving and validating
  names is the caller's job.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @units ~w(season episode)
  @watched_by_values ~w(all_started any selected)

  @primary_key false
  embedded_schema do
    field :enabled, :boolean, default: false
    field :unit, :string, default: "season"
    field :grace_days, :integer, default: 7
    field :watched_by, :string, default: "all_started"
    field :selected_users, {:array, :string}, default: []
  end

  @type t :: %__MODULE__{}

  @doc "The accepted `unit` values."
  def units, do: @units

  @doc "The accepted `watched_by` values."
  def watched_by_values, do: @watched_by_values

  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:enabled, :unit, :grace_days, :watched_by, :selected_users])
    |> validate_required([:enabled, :unit, :grace_days, :watched_by])
    |> validate_inclusion(:unit, @units)
    |> validate_inclusion(:watched_by, @watched_by_values)
    |> validate_number(:grace_days, greater_than_or_equal_to: 0)
    |> validate_selected_users()
  end

  defp validate_selected_users(changeset) do
    if get_field(changeset, :watched_by) == "selected" and
         get_field(changeset, :selected_users) in [nil, []] do
      add_error(
        changeset,
        :selected_users,
        "must name at least one user when watched_by is selected"
      )
    else
      changeset
    end
  end
end
