defmodule Mydia.Plugins.Index.BrowseResult do
  @moduledoc """
  The outcome of browsing every configured plugin source (R13).

  `catalog` holds every listed plugin, installed or not, as a `CatalogItem`.
  `status` is `:available` when any source listed a plugin and `:empty` when
  none did, so the store can say something explicit instead of rendering
  nothing.

  `error` is set when a source failed. It can accompany either status, because
  one failing source does not hide the entries of the sources that answered.
  """

  alias Mydia.Plugins.Index.CatalogItem

  @type status :: :available | :empty

  @type t :: %__MODULE__{
          catalog: [CatalogItem.t()],
          status: status(),
          error: String.t() | nil,
          source_count: non_neg_integer()
        }

  defstruct catalog: [], status: :empty, error: nil, source_count: 0
end
