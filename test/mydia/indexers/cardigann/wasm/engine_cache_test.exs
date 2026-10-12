defmodule Mydia.Indexers.Cardigann.Wasm.EngineCacheTest do
  # The precompiled cache, with the real guest: first start compiles and
  # writes the .cwasm, the next loads it, a corrupt one is rebuilt, and
  # leftovers of other versions are pruned. Restarts the application's Engine.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Mydia.Indexers.Cardigann.Wasm.{Artifact, Engine}

  @moduletag :cardigann_wasm
  @moduletag timeout: 180_000

  setup do
    {:ok, bytes} = Artifact.load()
    dir = Path.join(System.tmp_dir!(), "cardigann-cache-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    keys = [:cardigann_cache_dir, :cardigann_pinned_sha256]
    previous = Enum.map(keys, &{&1, Application.fetch_env(:mydia, &1)})
    previous_env = System.get_env("CARDIGANN_WASM_PATH")

    Application.put_env(:mydia, :cardigann_cache_dir, dir)
    Application.put_env(:mydia, :cardigann_pinned_sha256, Artifact.sha256(bytes))
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

    {:ok, dir: dir, cwasm: Path.join(dir, Artifact.cwasm_name())}
  end

  test "compiles once, caches the .cwasm, and loads it on the next start", ctx do
    assert start_and_wait()
    assert File.regular?(ctx.cwasm)
    assert File.stat!(ctx.cwasm).size > 1_000_000
    assert Path.wildcard(ctx.cwasm <> ".part-*") == []

    mtime = File.stat!(ctx.cwasm).mtime

    # Loaded, not rebuilt: the file is untouched and still the same size.
    size = File.stat!(ctx.cwasm).size
    Process.sleep(1_100)
    assert start_and_wait()
    assert %{mtime: ^mtime, size: ^size} = File.stat!(ctx.cwasm)
  end

  @tag :capture_log
  test "a corrupt .cwasm is deleted and rebuilt", ctx do
    File.write!(ctx.cwasm, "this is not a serialized component")

    log = capture_log(fn -> assert start_and_wait() end)

    assert log =~ "discarding"
    assert File.stat!(ctx.cwasm).size > 1_000_000
  end

  @tag :capture_log
  test "files of other versions are removed once the engine is loaded", ctx do
    stale = [
      "cardigann-0000000000000000.wasm",
      "cardigann-#{Artifact.source_hash()}-wasmtime1.0.0-x86_64.cwasm"
    ]

    for name <- stale, do: File.write!(Path.join(ctx.dir, name), "old")
    File.write!(Path.join(ctx.dir, "notes.txt"), "mine")

    assert start_and_wait()

    for name <- stale, do: refute(File.exists?(Path.join(ctx.dir, name)))
    assert File.exists?(Path.join(ctx.dir, "notes.txt"))
    assert File.exists?(ctx.cwasm)
  end

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
