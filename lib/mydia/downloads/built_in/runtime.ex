defmodule Mydia.Downloads.BuiltIn.Runtime do
  @moduledoc """
  What `BuiltIn.Manager` publishes about a running built-in client: the engine's
  API port and credentials and the `Config` it was started with. Stored by
  `Mydia.Downloads.BuiltIn.put_runtime/1`.
  """

  alias Mydia.Downloads.BuiltIn.Config

  @enforce_keys [:api_port, :credentials, :config]
  defstruct [:api_port, :credentials, :config]

  @type t :: %__MODULE__{
          api_port: pos_integer(),
          credentials: {String.t(), String.t()},
          config: Config.t()
        }
end
