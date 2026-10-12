defmodule Mydia.Indexers.Cardigann.Selector.Document do
  @moduledoc """
  A parsed HTML document plus the marker attributes standing in for each
  `:contains()` needle (see `Mydia.Indexers.Cardigann.Selector`).
  """

  @type t :: %__MODULE__{root: LazyHTML.t(), markers: %{String.t() => String.t()}}

  @enforce_keys [:root]
  defstruct [:root, markers: %{}]
end
