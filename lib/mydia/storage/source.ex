defmodule Mydia.Storage.Source do
  @moduledoc """
  One file inside a `Mydia.Storage.Location`. `path` is the absolute path for a
  local file and the `s3://` display path for an object. Use `path` for
  extensions, basenames and logging, never to open the file.
  """
  alias Mydia.Storage.Location

  @enforce_keys [:location, :relative_path, :path]
  defstruct [:location, :relative_path, :path]

  @type t :: %__MODULE__{location: Location.t(), relative_path: String.t(), path: String.t()}

  @spec new(Location.t(), String.t()) :: t()
  def new(%Location{} = location, relative_path) do
    %__MODULE__{
      location: location,
      relative_path: relative_path,
      path: Path.join(location.uri, relative_path)
    }
  end
end
