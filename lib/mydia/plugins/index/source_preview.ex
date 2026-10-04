defmodule Mydia.Plugins.Index.SourcePreview do
  @moduledoc "What adding a source would pin, shown to the admin before saving."

  @type t :: %__MODULE__{
          url: String.t(),
          name: String.t(),
          public_key: String.t(),
          fingerprint: String.t(),
          plugin_count: non_neg_integer()
        }

  @enforce_keys [:url, :name, :public_key, :fingerprint, :plugin_count]
  defstruct [:url, :name, :public_key, :fingerprint, :plugin_count]
end
