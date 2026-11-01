defmodule Mydia.Indexers.SearchResult.Source do
  @moduledoc """
  One tracker's copy of a release: the indexer that returned it and that
  indexer's details-page URL as reported. The URL is unchecked; render it only
  through `Mydia.Indexers.SearchResult.usable_info_url/1`.
  """

  @enforce_keys [:indexer]
  defstruct [:indexer, :info_url]

  @type t :: %__MODULE__{indexer: String.t(), info_url: String.t() | nil}
end
