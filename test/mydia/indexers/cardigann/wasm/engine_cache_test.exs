defmodule Mydia.Indexers.Cardigann.Wasm.EngineCacheTest do
  # The precompiled cache, with the real guest: first start compiles and
  # writes the .cwasm and its checksum, the next loads it, a corrupt or
  # tampered one is rebuilt, and leftovers of other versions are pruned.
  # Restarts the application's Engine.
  use ExUnit.Case, async: false

  alias Mydia.Indexers.Cardigann.Wasm.{Artifact, Engine}

  @moduletag :cardigann_wasm
  @moduletag timeout: 180_000

  setup do
    # Needs the Wasmex built from source with patches/wasmex (WASMEX_BUILD=1,
    # which devenv and ci.yml set). With the precompiled NIF the engine falls
    # back to compiling in memory and nothing here can be observed.
    unless patched_nif?() do
      flunk(
        "the Wasmex NIF lacks the Mydia patch (precompile_component_to_file): " <>
          "build it from source with WASMEX_BUILD=1 and `mix deps.compile wasmex --force`"
      )
    end

    {:ok, bytes} = Artifact.load()
    sha = Artifact.sha256(bytes)
    dir = Path.join(System.tmp_dir!(), "cardigann-cache-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    keys = [:cardigann_cache_dir, :cardigann_pinned_sha256]
    previous = Enum.map(keys, &{&1, Application.fetch_env(:mydia, &1)})
    previous_env = System.get_env("CARDIGANN_WASM_PATH")

    Application.put_env(:mydia, :cardigann_cache_dir, dir)
    Application.put_env(:mydia, :cardigann_pinned_sha256, sha)
    # The air-gapped path, so the test needs neither the network nor a release.
    System.put_env("CARDIGANN_WASM_PATH", Artifact.path())

    on_exit(fn ->
      stop_engine()

      for {key, value} <- previous do
        case value do
          {:ok, v} -> Application.put_env(:mydia, key, v)
          :error -> Application.delete_env(:mydia, key)
        end
      end

      if previous_env,
        do: System.put_env("CARDIGANN_WASM_PATH", previous_env),
        else: System.delete_env("CARDIGANN_WASM_PATH")

      File.rm_rf!(dir)
    end)

    cwasm = Path.join(dir, Artifact.cwasm_name(sha))
    {:ok, dir: dir, cwasm: cwasm, sidecar: cwasm <> ".sha256", sha: sha}
  end

  test "compiles once, caches the .cwasm with its checksum, and loads it on the next start",
       ctx do
    assert start_and_wait()
    assert File.regular?(ctx.cwasm)
    assert File.stat!(ctx.cwasm).size > 1_000_000
    assert Path.wildcard(ctx.cwasm <> ".part-*") == []

    # Named by the wasm checksum; the sidecar holds the .cwasm's own.
    assert Path.basename(ctx.cwasm) =~ ctx.sha
    assert String.trim(File.read!(ctx.sidecar)) == file_sha256(ctx.cwasm)

    # Only the app user may read the directory or the files.
    assert File.stat!(ctx.dir).mode |> Bitwise.band(0o777) == 0o700
    assert File.stat!(ctx.cwasm).mode |> Bitwise.band(0o777) == 0o600
    assert File.stat!(ctx.sidecar).mode |> Bitwise.band(0o777) == 0o600

    # Loaded, not rebuilt: the file is the same inode with the same bytes.
    inode = File.stat!(ctx.cwasm).inode
    before = file_sha256(ctx.cwasm)
    assert start_and_wait()
    assert File.stat!(ctx.cwasm).inode == inode
    assert file_sha256(ctx.cwasm) == before
  end

  @tag :capture_log
  test "a corrupt .cwasm is deleted and rebuilt", ctx do
    File.write!(ctx.cwasm, "this is not a serialized component")
    File.write!(ctx.sidecar, file_sha256(ctx.cwasm) <> "\n")

    assert start_and_wait()
    assert File.stat!(ctx.cwasm).size > 1_000_000
  end

  @tag :capture_log
  test "a .cwasm that no longer matches its checksum is rebuilt, not loaded", ctx do
    assert start_and_wait()
    good = File.read!(ctx.cwasm)

    # Same length, one byte changed: a flipped bit on disk, or a swapped file.
    <<head::binary-size(1000), byte, rest::binary>> = good
    File.write!(ctx.cwasm, <<head::binary, Bitwise.bxor(byte, 0xFF), rest::binary>>)
    assert file_sha256(ctx.cwasm) != String.trim(File.read!(ctx.sidecar))

    assert start_and_wait()
    assert String.trim(File.read!(ctx.sidecar)) == file_sha256(ctx.cwasm)
  end

  @tag :capture_log
  test "a .cwasm without a checksum file is not trusted", ctx do
    assert start_and_wait()
    File.rm!(ctx.sidecar)
    inode = File.stat!(ctx.cwasm).inode

    assert start_and_wait()
    assert File.exists?(ctx.sidecar)
    refute File.stat!(ctx.cwasm).inode == inode
  end

  @tag :capture_log
  test "files of other versions are removed once the engine is loaded", ctx do
    stale = [
      "cardigann-0000000000000000.wasm",
      "cardigann-#{ctx.sha}-wasmtime1.0.0-x86_64.cwasm",
      "cardigann-#{String.duplicate("0", 64)}-wasmtime47.0.2-x86_64.cwasm.sha256"
    ]

    for name <- stale, do: File.write!(Path.join(ctx.dir, name), "old")
    File.write!(Path.join(ctx.dir, "notes.txt"), "mine")

    assert start_and_wait()

    for name <- stale, do: refute(File.exists?(Path.join(ctx.dir, name)))
    assert File.exists?(Path.join(ctx.dir, "notes.txt"))
    assert File.exists?(ctx.cwasm)
    assert File.exists?(ctx.sidecar)
  end

  defp patched_nif? do
    Wasmex.Native.malloc_trim()
    true
  rescue
    ErlangError -> false
  end

  defp file_sha256(path), do: path |> File.read!() |> Artifact.sha256()

  defp start_and_wait do
    stop_engine()
    :ok = Engine.ensure_started()
    Engine.available?()
  end

  defp stop_engine do
    Supervisor.terminate_child(Mydia.Supervisor, Engine)
    Supervisor.delete_child(Mydia.Supervisor, Engine)
  end
end
