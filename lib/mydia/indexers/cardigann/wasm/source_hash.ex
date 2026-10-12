defmodule Mydia.Indexers.Cardigann.Wasm.SourceHash do
  @moduledoc """
  Hash of the Cardigann guest sources. It names the prebuilt artifact, so the
  source tree alone decides which build a checkout needs.

  The input is every tracked file under `native/cardigann_guest`, minus build
  output, docs and the `ARTIFACT_SHA256` pin. For each file, sorted by path, the
  hash covers `path <> <<0>> <> contents`. CI computes the same value with
  `native/cardigann_guest/scripts/source-hash.sh`; keep the exclusions in step.

  Inside a git checkout the file list is `git ls-files`. Docker and Nix builds
  have no `.git`, so there it walks the directory instead (the exclusions cover
  everything git would have ignored).
  """

  @guest_dir "native/cardigann_guest"
  @excluded ~r{/\.prowlarr/|/out/|/bin/|/obj/|/deny/target/|/deny/gen/|\.md$|/ARTIFACT_SHA256$}

  @doc "True when `file` (relative to the repo root) does not feed the hash."
  def excluded?(file), do: Regex.match?(@excluded, file)

  @doc "Files that feed the hash, relative to the repo root, byte-sorted."
  def tracked_files(mode \\ :auto, root \\ repo_root()) do
    mode
    |> list_files(root)
    |> Enum.reject(&excluded?/1)
    |> Enum.sort()
  end

  @doc "16 hex characters."
  def source_hash(mode \\ :auto, root \\ repo_root()) do
    mode
    |> tracked_files(root)
    |> Enum.reduce(:crypto.hash_init(:sha256), fn f, acc ->
      acc
      |> :crypto.hash_update(f <> "\0")
      |> :crypto.hash_update(File.read!(Path.join(root, f)))
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  def repo_root, do: Path.expand("../../../../..", __DIR__)

  defp list_files(:git, root) do
    {out, 0} = System.cmd("git", ["ls-files", "--", @guest_dir], cd: root, stderr_to_stdout: true)
    String.split(out, "\n", trim: true)
  end

  defp list_files(:walk, root) do
    root
    |> Path.join(@guest_dir)
    |> walk()
    |> Enum.map(&Path.relative_to(&1, root))
  end

  defp list_files(:auto, root) do
    if File.exists?(Path.join(root, ".git")) do
      list_files(:git, root)
    else
      list_files(:walk, root)
    end
  end

  defp walk(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.flat_map(entries, &walk_entry(Path.join(dir, &1)))
      {:error, _} -> []
    end
  end

  defp walk_entry(path), do: if(File.dir?(path), do: walk(path), else: [path])
end
