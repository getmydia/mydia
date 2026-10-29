defmodule Mydia.Indexers.Cardigann.Parity.Divergence do
  @moduledoc """
  One observed difference between the native and wasm engines for a single
  definition and query kind.

  `kind` says what differed: the whole outcome (one side errored), the HTTP
  requests (a request had no recording), the result count, or one result
  field. `field` is only set for `:field`.
  """

  @enforce_keys [:definition, :query, :kind]
  defstruct [:definition, :query, :kind, :field, :native, :wasm]

  @type kind :: :outcome | :request | :count | :field

  @type t :: %__MODULE__{
          definition: String.t(),
          query: atom(),
          kind: kind(),
          field: atom() | nil,
          native: term(),
          wasm: term()
        }

  @type key :: {String.t(), atom(), kind(), atom() | nil}

  @doc "The identity the ratchet file matches on; values are not part of it."
  @spec key(t()) :: key()
  def key(%__MODULE__{} = d), do: {d.definition, d.query, d.kind, d.field}
end
