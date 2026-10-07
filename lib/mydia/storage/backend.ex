defmodule Mydia.Storage.Backend do
  @moduledoc "Callbacks implemented by `Mydia.Storage.Local` and `Mydia.Storage.S3`."
  alias Mydia.Storage.{Entry, Error, Location}

  @type rel :: String.t()
  @type fold :: (binary(), term() -> {:ok, term()} | {:error, term()})

  @callback list(Location.t()) :: {:ok, [Entry.t()]} | {:error, Error.t()}
  @callback validate(Location.t()) :: :ok | {:error, Error.t()}
  @callback stat(Location.t(), rel()) :: {:ok, Entry.t()} | {:error, Error.t()}
  @callback input(Location.t(), rel()) :: {:ok, String.t()} | {:error, Error.t()}
  @callback read_range(Location.t(), rel(), non_neg_integer(), pos_integer()) ::
              {:ok, binary()} | {:error, Error.t()}
  @callback stream_range(Location.t(), rel(), non_neg_integer(), pos_integer(), term(), fold()) ::
              {:ok, term()} | {:error, Error.t() | term()}
end
