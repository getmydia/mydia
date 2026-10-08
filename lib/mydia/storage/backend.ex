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

  # Writes. `copy/4` and `move/4` are only called with two locations on the
  # same backend; `Mydia.Storage` handles every other pair.
  @callback put_file(Location.t(), rel(), Path.t(), keyword()) :: :ok | {:error, Error.t()}
  @callback put_binary(Location.t(), rel(), iodata(), keyword()) :: :ok | {:error, Error.t()}
  @callback copy(Location.t(), rel(), Location.t(), rel()) :: :ok | {:error, Error.t()}
  @callback move(Location.t(), rel(), Location.t(), rel()) :: :ok | {:error, Error.t()}
  @callback delete(Location.t(), rel()) :: :ok | {:error, Error.t()}
  @callback delete_prefix(Location.t(), rel()) :: :ok | {:error, Error.t()}
  @callback ls(Location.t(), rel()) :: {:ok, [String.t()]} | {:error, Error.t()}
end
