defmodule Mydia.SmartSpace.Override do
  @moduledoc """
  Per-show Smart Space override. A show without a row inherits the global rule.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Mydia.Media.MediaItem

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # "inherit" is never stored: it means no row (see Rules.put_override/2).
  @modes ~w(off custom)
  @units ~w(season episode)

  @type t :: %__MODULE__{}

  schema "smart_space_overrides" do
    field :mode, :string
    field :unit, :string
    field :grace_days, :integer

    belongs_to :media_item, MediaItem

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for an override. `media_item_id` is set by the caller on the struct."
  def changeset(override, attrs) do
    override
    |> cast(attrs, [:mode, :unit, :grace_days])
    |> validate_required([:mode, :media_item_id])
    |> validate_inclusion(:mode, @modes)
    |> validate_inclusion(:unit, @units)
    |> validate_number(:grace_days, greater_than_or_equal_to: 0)
    |> validate_custom()
    |> foreign_key_constraint(:media_item_id)
    |> unique_constraint(:media_item_id)
  end

  defp validate_custom(changeset) do
    if get_field(changeset, :mode) == "custom" do
      validate_required(changeset, [:unit, :grace_days])
    else
      changeset
    end
  end
end
