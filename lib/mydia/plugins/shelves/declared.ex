defmodule Mydia.Plugins.Shelves.Declared do
  @moduledoc "One shelf as one plugin's manifest declares it."

  @enforce_keys [:slug, :key, :title, :placement, :scope, :ttl_seconds, :refresh_on]
  defstruct [:slug, :key, :title, :placement, :scope, :ttl_seconds, :refresh_on]

  @type t :: %__MODULE__{
          slug: String.t(),
          key: String.t(),
          title: String.t(),
          placement: String.t(),
          scope: String.t(),
          ttl_seconds: pos_integer(),
          refresh_on: [String.t()]
        }
end
