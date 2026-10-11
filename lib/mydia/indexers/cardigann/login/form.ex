defmodule Mydia.Indexers.Cardigann.Login.Form do
  @moduledoc "Placeholder for the `form` login strategy, replaced in the next task."

  alias Mydia.Indexers.Adapter.Error

  @spec begin(map()) :: {:error, Error.t()}
  def begin(_args), do: {:error, Error.invalid_config("form login is not implemented yet")}

  @spec complete(term(), map()) :: {:error, Error.t()}
  def complete(_challenge, _answers),
    do: {:error, Error.invalid_config("form login is not implemented yet")}
end
