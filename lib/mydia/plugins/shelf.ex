defmodule Mydia.Plugins.Shelf do
  @moduledoc """
  One plugin shelf for one user: when it was last filled, when it goes stale,
  and how its last fill ended. The items live in `Mydia.Plugins.ShelfItem`.

  `stale_at` is `nil` until the first fill, which reads as stale.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "plugin_shelves" do
    field :plugin_slug, :string
    field :shelf_key, :string
    field :user_id, :binary_id
    field :status, Ecto.Enum, values: [:idle, :failed], default: :idle
    field :filled_at, :utc_datetime_usec
    field :stale_at, :utc_datetime_usec
    field :failure_count, :integer, default: 0
    field :last_error, :string

    has_many :items, Mydia.Plugins.ShelfItem, preload_order: [asc: :position]

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Bookkeeping changes only: identity is set when the row is built."
  def changeset(shelf, attrs) do
    shelf
    |> cast(attrs, [:status, :filled_at, :stale_at, :failure_count, :last_error])
    |> validate_required([:plugin_slug, :shelf_key, :user_id, :status])
    |> validate_number(:failure_count, greater_than_or_equal_to: 0)
    |> validate_length(:last_error, max: 500)
    |> unique_constraint([:plugin_slug, :shelf_key, :user_id])
  end
end
