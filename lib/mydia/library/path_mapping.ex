defmodule Mydia.Library.PathMapping do
  @moduledoc """
  Applies configured remote→local prefix rewrites to paths reported by download
  clients, and classifies whether a missing path is a container mount-mismatch
  rather than a genuinely missing file.

  See `Mydia.Settings.PathMappingConfig` for the configuration model.
  """

  alias Mydia.Library.MountRoots
  alias Mydia.Settings

  # Bound the basename search so a pathological mount tree can't stall the
  # suggestion. Q3 in the plan flags revisiting this against real costs.
  @max_scan_depth 6

  @doc """
  Suggests a remote→local prefix mapping for a reported path Mydia couldn't see.

  Scans the detected mount roots for a directory whose basename matches the
  reported path's basename. Returns `{:ok, %{remote_prefix, local_prefix}}` only
  on exactly one match — the single-match gate guards against ambiguity, not
  against a confidently-wrong match, so callers must present the suggestion for
  explicit confirmation. Zero or multiple matches return `:none`.

  `roots` defaults to `MountRoots.detect/0`; pass an explicit list in tests.
  """
  @spec suggest(String.t(), [String.t()] | nil) :: {:ok, map()} | :none
  def suggest(reported_path, roots \\ nil)

  def suggest(reported_path, roots) when is_binary(reported_path) do
    basename = Path.basename(reported_path)
    roots = roots || MountRoots.detect()

    matches =
      roots
      |> Enum.flat_map(&find_dirs_named(&1, basename, @max_scan_depth))
      |> Enum.uniq()

    case matches do
      [local_dir] ->
        {:ok,
         %{
           remote_prefix: Path.dirname(reported_path),
           local_prefix: Path.dirname(local_dir)
         }}

      _ ->
        :none
    end
  end

  def suggest(_reported_path, _roots), do: :none

  @doc """
  Rewrites `path` through the longest matching configured remote prefix.

  Returns the path unchanged when no prefix matches. The rewritten result is
  canonicalized; if the rewrite would escape its local prefix (via `..`), the
  original path is returned unchanged so the importer fails as a mismatch rather
  than reading an unintended directory.
  """
  @spec rewrite(String.t()) :: String.t()
  def rewrite(path) when is_binary(path) do
    case Enum.find(Settings.list_path_mapping_configs(), &under_prefix?(path, &1.remote_prefix)) do
      nil -> path
      mapping -> apply_mapping(path, mapping)
    end
  end

  def rewrite(path), do: path

  @doc """
  True when the reported path looks like a container volume mount-mismatch: its
  immediate parent directory is not visible inside Mydia's filesystem.

  A genuinely deleted leaf keeps a visible parent and returns `false`; the
  `/downloads` visible / `/downloads/complete` invisible layout returns `true`.
  """
  @spec mount_mismatch?(String.t()) :: boolean()
  def mount_mismatch?(path) when is_binary(path) do
    not File.exists?(Path.dirname(path))
  end

  def mount_mismatch?(_), do: false

  defp find_dirs_named(_dir, _name, depth) when depth < 0, do: []

  defp find_dirs_named(dir, name, depth) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          full = Path.join(dir, entry)

          if File.dir?(full) do
            here = if entry == name, do: [full], else: []
            here ++ find_dirs_named(full, name, depth - 1)
          else
            []
          end
        end)

      _ ->
        []
    end
  end

  defp under_prefix?(path, prefix) when is_binary(prefix) do
    path == prefix or String.starts_with?(path, prefix <> "/")
  end

  defp under_prefix?(_path, _prefix), do: false

  defp apply_mapping(path, %{remote_prefix: remote, local_prefix: local}) do
    candidate =
      path
      |> String.replace_prefix(remote, local)
      |> Path.expand()

    # Defense in depth: the stored prefixes are validated to be absolute and
    # free of `..`, but the path tail comes from the download client. If the
    # canonicalized result escapes the local prefix, refuse the rewrite.
    if under_local_prefix?(candidate, local) do
      candidate
    else
      path
    end
  end

  defp under_local_prefix?(candidate, "/"), do: String.starts_with?(candidate, "/")

  defp under_local_prefix?(candidate, local) when is_binary(local) do
    candidate == local or String.starts_with?(candidate, local <> "/")
  end
end
