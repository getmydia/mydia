defmodule Mydia.LibraryApi.RevisionClockState do
  @moduledoc """
  The singleton UTC-day watermark for the Library API revision clock.

  One row, always `id = 1`, holding the last UTC date the sweep has processed.
  The database's `CHECK (id = 1)` constraint makes it a singleton at the storage
  layer rather than by convention, so no application code can create a second.

  The row is read and written only inside `Mydia.LibraryApi.RevisionClock`'s
  transaction. It is not a changeset-backed resource: application callers never
  accept arbitrary attributes for it.
  """

  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}

  @type t :: %__MODULE__{
          id: integer(),
          last_processed_date: Date.t()
        }

  schema "library_revision_clock" do
    field :last_processed_date, :date
  end
end
