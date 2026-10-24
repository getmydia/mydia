defmodule Mydia.Locale.Info do
  @moduledoc "One interface language as the language picker shows it."

  @enforce_keys [:code, :native_name, :completion]
  defstruct [:code, :native_name, :completion]

  @type t :: %__MODULE__{code: String.t(), native_name: String.t(), completion: float()}
end
