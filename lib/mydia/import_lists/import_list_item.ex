defmodule Mydia.ImportLists.ImportListItem do
  @moduledoc """
  Schema for import list items.

  An import list item represents a single media item discovered from an import list.
  Items are tracked from discovery through being added to the library or failed.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @status_values ~w(pending added failed)

  @type t :: %__MODULE__{
          id: binary(),
          tmdb_id: integer() | nil,
          title: String.t() | nil,
          year: integer() | nil,
          poster_path: String.t() | nil,
          status: String.t(),
          skip_reason: String.t() | nil,
          discovered_at: DateTime.t() | nil,
          in_library: boolean(),
          import_list: Mydia.ImportLists.ImportList.t() | Ecto.Association.NotLoaded.t(),
          media_item: Mydia.Media.MediaItem.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "import_list_items" do
    field :tmdb_id, :integer
    field :title, :string
    field :year, :integer
    field :poster_path, :string
    field :status, :string, default: "pending"
    field :skip_reason, :string
    field :discovered_at, :utc_datetime

    # Virtual field: true if the media_item still exists in the library
    field :in_library, :boolean, virtual: true, default: false

    belongs_to :import_list, Mydia.ImportLists.ImportList
    belongs_to :media_item, Mydia.Media.MediaItem

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating an import list item.
  """
  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :tmdb_id,
      :title,
      :year,
      :poster_path,
      :status,
      :skip_reason,
      :discovered_at,
      :import_list_id,
      :media_item_id
    ])
    |> validate_required([:tmdb_id, :title, :discovered_at, :import_list_id])
    |> validate_inclusion(:status, @status_values)
    |> unique_constraint([:import_list_id, :tmdb_id], name: :import_list_items_list_tmdb_unique)
    |> foreign_key_constraint(:import_list_id)
    |> foreign_key_constraint(:media_item_id)
  end

  @doc """
  Returns the list of valid status values.
  """
  def valid_statuses, do: @status_values

  @doc """
  The state an operator sees: `"in_library"` when matching media exists
  (linked or by TMDB id), `"failed"` for a failed add not in the library,
  `"pending"` otherwise (including an `"added"` row whose media was deleted).
  Requires `in_library` to have been computed by the item queries in
  `Mydia.ImportLists`.
  """
  @spec effective_status(t()) :: String.t()
  def effective_status(%__MODULE__{in_library: true}), do: "in_library"
  def effective_status(%__MODULE__{status: "failed"}), do: "failed"
  def effective_status(%__MODULE__{}), do: "pending"

  @doc """
  Returns a human-readable label for a status.
  """
  def status_label("pending"), do: "Pending"
  def status_label("added"), do: "Added"
  def status_label("failed"), do: "Failed"
  def status_label(_), do: "Unknown"
end
