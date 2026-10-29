defmodule Mydia.Indexers.Cardigann.Parity.Capture.Exchange do
  @moduledoc "One recorded request and its response (or transport error)."

  alias Mydia.Indexers.Cardigann.Parity.RequestKey

  @enforce_keys [:request]
  defstruct [:request, :status, :body, :error, headers: []]

  @type t :: %__MODULE__{
          request: RequestKey.t(),
          status: non_neg_integer() | nil,
          headers: [{String.t(), String.t()}],
          body: binary() | nil,
          error: atom() | nil
        }
end
