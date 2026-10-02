defmodule Mydia.Plugins.Shelves.View do
  @moduledoc "A shelf with its stored items, as a page needs it to render."

  alias Mydia.Plugins.Shelf
  alias Mydia.Plugins.ShelfItem
  alias Mydia.Plugins.Shelves.Declared

  @enforce_keys [:declared, :shelf, :items, :stale?]
  defstruct [:declared, :shelf, :items, :stale?]

  @type t :: %__MODULE__{
          declared: Declared.t(),
          shelf: Shelf.t(),
          items: [ShelfItem.t()],
          stale?: boolean()
        }
end
