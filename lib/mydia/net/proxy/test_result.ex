defmodule Mydia.Net.Proxy.TestResult do
  @moduledoc """
  A successful `Mydia.Net.Proxy.test_connection/1`: the HTTP status the target
  answered through the proxy and the round trip in milliseconds.
  """

  @enforce_keys [:status, :ms]
  defstruct [:status, :ms]

  @type t :: %__MODULE__{status: integer(), ms: non_neg_integer()}
end
