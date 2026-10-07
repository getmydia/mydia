defmodule Mydia.Storage.Entry do
  @moduledoc "One file in a storage location."
  @enforce_keys [:relative_path, :size, :mtime]
  defstruct [:relative_path, :size, :mtime]

  @type t :: %__MODULE__{
          relative_path: String.t(),
          size: non_neg_integer(),
          mtime: DateTime.t()
        }
end
