defmodule Mydia.Plugins.Index.PublicKey do
  @moduledoc """
  A parsed minisign Ed25519 public key. `encoded` is the base64 line as it
  appears in a `.pub` file, which is what gets stored and displayed.
  """

  @type t :: %__MODULE__{key_id: binary(), key: binary(), encoded: String.t()}

  @enforce_keys [:key_id, :key, :encoded]
  defstruct [:key_id, :key, :encoded]
end
