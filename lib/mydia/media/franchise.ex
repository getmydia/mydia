defmodule Mydia.Media.Franchise do
  @moduledoc """
  A movie's franchise, as shown on its detail page.

  Named "franchise" rather than "collection" so it does not collide with
  `Mydia.Collections`, which means user-curated lists. The provider-shape
  equivalent is `Mydia.Metadata.Structs.Collection`.
  """

  alias Mydia.Media.FranchiseEntry

  @enforce_keys [:name, :entries, :owned_count, :total_count]
  defstruct [:name, :entries, :owned_count, :total_count]

  @type t :: %__MODULE__{
          name: String.t() | nil,
          entries: [FranchiseEntry.t()],
          owned_count: non_neg_integer(),
          total_count: non_neg_integer()
        }
end
