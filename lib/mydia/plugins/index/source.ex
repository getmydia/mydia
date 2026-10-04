defmodule Mydia.Plugins.Index.Source do
  @moduledoc """
  A catalog to fetch and the key it must be signed with. `id` is the
  `plugin_sources` row id, or `nil` for the official index.
  """

  alias Mydia.Plugins.Index.PublicKey

  @type t :: %__MODULE__{
          id: binary() | nil,
          url: String.t(),
          name: String.t(),
          public_key: PublicKey.t(),
          official?: boolean()
        }

  @enforce_keys [:url, :name, :public_key]
  defstruct [:id, :url, :name, :public_key, official?: false]
end
