defmodule Mydia.LibraryApi.MediaItemRevision do
  @moduledoc """
  The latest aggregate Library API revision for one media-item UUID.

  One row per media item, created and advanced by database triggers rather than
  application code, so a write that bypasses the contexts (a bulk `update_all`, a
  cascade, a future caller) still advances it. `revision` is the ordering key and
  the primary key; `media_item_id` is unique and deliberately has no foreign key,
  because a tombstone for a deleted item must survive the item's own deletion.

  There is no changeset: application callers never accept arbitrary attributes for
  a row the database owns.
  """

  use Ecto.Schema

  # `:id`, not `:integer`: only the `:id` type carries Ecto's `autogenerate: true`
  # support for a database-assigned integer key, which is the identity column on
  # PostgreSQL and `INTEGER PRIMARY KEY AUTOINCREMENT` on SQLite.
  @primary_key {:revision, :id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          revision: pos_integer(),
          media_item_id: Ecto.UUID.t(),
          deleted: boolean(),
          changed_at: DateTime.t()
        }

  schema "media_item_revisions" do
    field :media_item_id, :binary_id
    field :deleted, :boolean, default: false
    field :changed_at, :utc_datetime_usec
  end
end
