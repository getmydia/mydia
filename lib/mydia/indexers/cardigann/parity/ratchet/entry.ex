defmodule Mydia.Indexers.Cardigann.Parity.Ratchet.Entry do
  @moduledoc "One accepted divergence and why it is accepted."

  alias Mydia.Indexers.Cardigann.Parity.Divergence

  @enforce_keys [:definition, :query, :kind, :reason]
  defstruct [:definition, :query, :kind, :field, :reason]

  @type t :: %__MODULE__{
          definition: String.t(),
          query: atom(),
          kind: Divergence.kind(),
          field: atom() | nil,
          reason: String.t()
        }

  @spec key(t()) :: Divergence.key()
  def key(%__MODULE__{} = e), do: {e.definition, e.query, e.kind, e.field}
end
