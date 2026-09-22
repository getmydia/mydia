defmodule Mydia.Library.Dirs do
  @moduledoc """
  Path containment and empty-directory pruning under a library root.

  Containment compares against `root <> "/"` on expanded paths. A plain
  `String.starts_with?(path, root)` reads `/media/tv2` as inside `/media/tv`,
  which is how `Mydia.Library.FileOrganizer` used to be willing to prune a
  sibling library's empty directories.
  """

  @doc """
  True when `path` sits strictly below `root`. A path is never inside itself.
  """
  @spec inside?(String.t(), String.t()) :: boolean()
  def inside?(path, root) when is_binary(path) and is_binary(root) do
    prefix = root |> Path.expand() |> String.trim_trailing("/")
    String.starts_with?(Path.expand(path), prefix <> "/")
  end

  @doc """
  Removes `dir` if it is empty, then its parent, and so on, stopping at the
  first directory that is not empty, cannot be read, or is not strictly
  inside `root`. `root` itself is never removed.
  """
  @spec prune_empty(String.t(), String.t()) :: :ok
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
