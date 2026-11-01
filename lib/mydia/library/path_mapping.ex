defmodule Mydia.Library.PathMapping do
  @moduledoc """
  Applies configured remote→local prefix rewrites to paths reported by download
  clients, and classifies whether a missing path is a container mount-mismatch
  rather than a genuinely missing file.

  See `Mydia.Settings.PathMappingConfig` for the configuration model.
  """

  require Logger

  alias Mydia.Library.MountRoots
  alias Mydia.Settings

  # Bounds for the basename walk, which only runs when the suffix join finds
  # nothing. Totals for one call across every root. A walk that runs out
  # returns :none: it cannot prove the match it saw is the only one.
  @max_scan_depth 6
  @max_scan_dirs 20_000
  @max_scan_ms 5_000
  @scan_timeout_margin_ms 1_000

  @doc """
  Suggests a remote→local prefix mapping for a reported path Mydia couldn't see.

  Tries a suffix join first: each root joined with the reported path's
  trailing segments, longest first (`downloads/complete/X`, `complete/X`,
  `X`). The longest tail that names any directory decides. If it names exactly
  one, that is the match. Otherwise the search falls back to walking each root
  (up to #{@max_scan_depth} levels) for a directory with the reported basename,
  within a budget of #{@max_scan_dirs} directories and #{@max_scan_ms}ms.

  Returns `{:ok, %{remote_prefix, local_prefix}}` only on exactly one match.
  The single-match gate guards against ambiguity, not against a
  confidently-wrong match, so callers must present the suggestion for explicit
  confirmation. Zero or multiple matches, or a walk that ran out of budget,
  return `:none`.

  `roots` defaults to `search_roots/0`; pass an explicit list in tests.
  Options `:max_scan_dirs` and `:max_scan_ms` override the walk budgets.
  """
  @spec suggest(String.t(), [String.t()] | nil, keyword()) :: {:ok, map()} | :none
  def suggest(reported_path, roots \\ nil, opts \\ [])

  def suggest(reported_path, roots, opts) when is_binary(reported_path) do
    roots = roots || search_roots()

    case suffix_match(reported_path, roots) do
      {:ok, local_dir} -> {:ok, mapping(reported_path, local_dir)}
      :none -> walk_match(reported_path, roots, opts)
    end
  end

  def suggest(_reported_path, _roots, _opts), do: :none

  @doc """
  The roots `suggest/3` searches by default: the `:path_mapping_roots` app env
  when set (the test config sets `[]`), otherwise `MountRoots.detect/0`.
  """
  @spec search_roots() :: [String.t()]
  def search_roots do
    Application.get_env(:mydia, :path_mapping_roots) || MountRoots.detect()
  end

  @doc """
  The `Mydia.Downloads.Download` attrs recording a suggestion search for
  `reported_path`: both prefixes on a match, both nil otherwise, and
  `path_mapping_searched_at` set either way.

  Never raises and never blocks past the wall-clock bound. An import failure
  must still be recorded when the search crashes or hangs, so either is logged
  and stored as "searched, nothing found".

  The walk checks its budget only between directory operations, so one
  `File.ls/1` on a hung network mount could block forever. The search therefore
  runs in a task that is killed after the walk budget plus a margin. The walk
  uses non-raw `File` calls, which are gen_server calls into `file_server_2`,
  so the task process is killable (see `Mydia.Library.MountRoots.reachable_dirs/2`).

  Options (for tests): `:timeout_ms` overrides the wall-clock bound and
  `:search_fun` (arity 2, `(path, roots)`) replaces `suggest/2`.
  """
  @spec suggestion_attrs(String.t(), [String.t()] | nil, keyword()) :: map()
  def suggestion_attrs(reported_path, roots \\ nil, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, @max_scan_ms + @scan_timeout_margin_ms)
    search_fun = Keyword.get(opts, :search_fun, &suggest/2)

    task = Task.async(fn -> safe_search(search_fun, reported_path, roots) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        searched_attrs(result)

      {:exit, reason} ->
        Logger.warning(
          "Path-mapping suggestion search exited for #{inspect(reported_path)}: " <>
            inspect(reason)
        )

        searched_attrs(:none)

      nil ->
        Logger.warning(
          "Path-mapping suggestion search for #{inspect(reported_path)} " <>
            "timed out after #{timeout}ms; recording it as searched"
        )

        searched_attrs(:none)
    end
  end

  defp safe_search(search_fun, reported_path, roots) do
    search_fun.(reported_path, roots)
  rescue
    error ->
      Logger.warning(
        "Path-mapping suggestion search failed for #{inspect(reported_path)}: " <>
          Exception.message(error)
      )

      :none
  end

  defp searched_attrs(result) do
    {remote, local} =
      case result do
        {:ok, %{remote_prefix: remote, local_prefix: local}} -> {remote, local}
        :none -> {nil, nil}
      end

    %{
      path_mapping_remote_prefix: remote,
      path_mapping_local_prefix: local,
      path_mapping_searched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  defp mapping(reported_path, local_dir) do
    %{remote_prefix: Path.dirname(reported_path), local_prefix: Path.dirname(local_dir)}
  end

  # The longest tail that names a directory under any root decides: one
  # directory is the match, several are ambiguous and fall through to the walk.
  defp suffix_match(reported_path, roots) do
    reported_path
    |> trailing_slices()
    |> Enum.find_value(:none, fn slice ->
      case roots |> Enum.map(&Path.join(&1, slice)) |> Enum.filter(&File.dir?/1) |> Enum.uniq() do
        [] -> nil
        [local_dir] -> {:ok, local_dir}
        _ambiguous -> :none
      end
    end)
  end

  # "/downloads/complete/X" => ["downloads/complete/X", "complete/X", "X"].
  # A path with a ".." segment gets no slices: joining it could name a
  # directory outside the root.
  defp trailing_slices(path) do
    segments = path |> Path.split() |> Enum.reject(&(&1 == "/"))

    if ".." in segments do
      []
    else
      for n <- length(segments)..1//-1, do: segments |> Enum.take(-n) |> Path.join()
    end
  end

  defp walk_match(reported_path, roots, opts) do
    budget = %{
      dirs_left: Keyword.get(opts, :max_scan_dirs, @max_scan_dirs),
      deadline:
        System.monotonic_time(:millisecond) + Keyword.get(opts, :max_scan_ms, @max_scan_ms)
    }

    name = Path.basename(reported_path)

    result =
      Enum.reduce_while(roots, {[], budget}, fn root, {found, budget} ->
        case find_dirs_named(root, name, @max_scan_depth, budget) do
          {:ok, here, budget} -> {:cont, {found ++ here, budget}}
          :exhausted -> {:halt, :exhausted}
        end
      end)

    case result do
      {found, _budget} ->
        case Enum.uniq(found) do
          [local_dir] -> {:ok, mapping(reported_path, local_dir)}
          _ -> :none
        end

      :exhausted ->
        :none
    end
  end

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

  defp find_dirs_named(_dir, _name, depth, budget) when depth < 0, do: {:ok, [], budget}

  defp find_dirs_named(dir, name, depth, budget) do
    cond do
      budget.dirs_left <= 0 ->
        :exhausted

      System.monotonic_time(:millisecond) >= budget.deadline ->
        :exhausted

      true ->
        budget = %{budget | dirs_left: budget.dirs_left - 1}

        case File.ls(dir) do
          {:ok, entries} -> scan_entries(entries, dir, name, depth, budget, [])
          _ -> {:ok, [], budget}
        end
    end
  end

  defp scan_entries([], _dir, _name, _depth, budget, found), do: {:ok, found, budget}

  defp scan_entries([entry | rest], dir, name, depth, budget, found) do
    if System.monotonic_time(:millisecond) >= budget.deadline do
      :exhausted
    else
      scan_entry(entry, rest, dir, name, depth, budget, found)
    end
  end

  defp scan_entry(entry, rest, dir, name, depth, budget, found) do
    full = Path.join(dir, entry)

    if File.dir?(full) do
      here = if entry == name, do: [full], else: []

      case find_dirs_named(full, name, depth - 1, budget) do
        {:ok, below, budget} ->
          scan_entries(rest, dir, name, depth, budget, found ++ here ++ below)

        :exhausted ->
          :exhausted
      end
    else
      scan_entries(rest, dir, name, depth, budget, found)
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
