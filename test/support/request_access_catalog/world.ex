defmodule Mydia.RequestAccessCatalog.World do
  @moduledoc "What `Mydia.RequestAccessCatalog.seed!/0` returns."
  @enforce_keys [:bypass, :titles]
  defstruct [:bypass, :titles]
end
