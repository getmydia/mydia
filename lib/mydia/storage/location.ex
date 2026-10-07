defmodule Mydia.Storage.Location do
  @moduledoc """
  A parsed library root: a local directory, or a prefix inside a named S3
  storage backend (`s3://<backend>/<prefix>`).

  `uri` is the library path string exactly as stored. `Path.join/2`,
  `Path.relative_to/2` and `Path.dirname/1` behave on `s3://` strings, so code
  that only joins and splits paths keeps working. `Path.expand/1` does not:
  never expand an `s3://` path.
  """

  @enforce_keys [:kind, :uri]
  defstruct [:kind, :uri, :root, :backend, prefix: ""]

  @type t :: %__MODULE__{
          kind: :local | :s3,
          uri: String.t(),
          root: String.t() | nil,
          backend: struct() | map() | nil,
          prefix: String.t()
        }

  @spec local(String.t()) :: t()
  def local(root) when is_binary(root), do: %__MODULE__{kind: :local, uri: root, root: root}

  @spec s3(struct() | map(), String.t(), String.t()) :: t()
  def s3(backend, prefix, uri),
    do: %__MODULE__{kind: :s3, uri: uri, backend: backend, prefix: prefix}

  @spec s3_path?(term()) :: boolean()
  def s3_path?("s3://" <> _), do: true
  def s3_path?(_), do: false

  @spec parse_s3(String.t()) :: {:ok, String.t(), String.t()} | :error
  def parse_s3("s3://" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [""] -> :error
      ["" | _] -> :error
      [name] -> {:ok, name, ""}
      [name, prefix] -> {:ok, name, normalize_prefix(prefix)}
    end
  end

  def parse_s3(_), do: :error

  @spec key(t(), String.t()) :: String.t()
  def key(%__MODULE__{kind: :s3, prefix: prefix}, relative_path), do: prefix <> relative_path

  defp normalize_prefix(prefix) do
    case prefix |> String.split("/", trim: true) |> Enum.join("/") do
      "" -> ""
      joined -> joined <> "/"
    end
  end
end
