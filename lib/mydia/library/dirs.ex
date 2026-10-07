defmodule Mydia.Library.Dirs do
  @moduledoc """
  Path containment and empty-directory pruning under a library root.

  Containment compares against `root <> "/"` on expanded paths. A plain
  `String.starts_with?(path, root)` reads `/media/tv2` as inside `/media/tv`,
  which is how `Mydia.Library.FileOrganizer` used to be willing to prune a
  sibling library's empty directories.
  """

  @doc """
  `Path.expand/1` for a local path. An `s3://` URI only loses its trailing
  slash: expanding one would turn the scheme into a directory under the
  working directory.
  """
  @spec normalize(String.t()) :: String.t()
  def normalize("s3://" <> _ = uri), do: String.trim_trailing(uri, "/")
  def normalize(path), do: Path.expand(path)

  @doc """
  True when `path` sits strictly below `root`. A path is never inside itself.
  """
  @spec inside?(String.t(), String.t()) :: boolean()
  def inside?(path, root) when is_binary(path) and is_binary(root) do
    prefix = root |> normalize() |> String.trim_trailing("/")
    String.starts_with?(normalize(path), prefix <> "/")
  end

  @doc """
  Removes `dir` if it is empty, then its parent, and so on, stopping at the
  first directory that is not empty, cannot be read, or is not strictly
  inside `root`. `root` itself is never removed. Does nothing for `s3://`
  roots or directories: object storage has no empty directories.
  """
  @spec prune_empty(String.t(), String.t()) :: :ok
  def prune_empty("s3://" <> _, _root), do: :ok
  def prune_empty(_dir, "s3://" <> _), do: :ok

  def prune_empty(dir, root) when is_binary(dir) and is_binary(root) do
    with true <- inside?(dir, root),
         {:ok, []} <- File.ls(dir),
         :ok <- File.rmdir(dir) do
      prune_empty(Path.dirname(dir), root)
    else
      _ -> :ok
    end
  end
end
