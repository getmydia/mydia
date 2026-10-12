defmodule Mydia.Indexers.Cardigann.Wasm.DeliveryTest do
  # Runs against stand-in bytes: delivery only hashes and moves files. It sets
  # application and OS env, so it cannot share the VM with other async tests.
  use ExUnit.Case, async: false

  alias Mydia.Indexers.Cardigann.Wasm.{Artifact, Delivery}

  @bytes "not really a component, just bytes with a known hash"
  @keys [
    :cardigann_cache_dir,
    :cardigann_guest_base_url,
    :cardigann_pinned_sha256,
    :cardigann_wasm_path
  ]

  setup do
    previous = Enum.map(@keys, &{&1, Application.fetch_env(:mydia, &1)})
    previous_env = System.get_env("CARDIGANN_WASM_PATH")

    dir = Path.join(System.tmp_dir!(), "cardigann-delivery-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    bypass = Bypass.open()

    Application.put_env(:mydia, :cardigann_cache_dir, Path.join(dir, "cache"))
    Application.put_env(:mydia, :cardigann_guest_base_url, "http://localhost:#{bypass.port}/dl")
    Application.put_env(:mydia, :cardigann_pinned_sha256, Artifact.sha256(@bytes))
    # No development artifact: only the paths under test can satisfy a lookup.
    Application.put_env(:mydia, :cardigann_wasm_path, Path.join(dir, "no-dev-artifact.wasm"))
    System.delete_env("CARDIGANN_WASM_PATH")

    on_exit(fn ->
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

    {:ok, dir: dir, bypass: bypass, cached: Path.join([dir, "cache", Artifact.file_name()])}
  end

  defp serve(bypass, bytes, status \\ 200) do
    name = "/dl/" <> Artifact.file_name()

    Bypass.expect_once(bypass, "GET", name, fn conn -> Plug.Conn.resp(conn, status, bytes) end)
  end

  describe "download" do
    test "fetches the pinned file, verifies it and writes it atomically", ctx do
      serve(ctx.bypass, @bytes)

      assert {:ok, path} = Delivery.ensure()
      assert path == ctx.cached
      assert File.read!(path) == @bytes
      assert Path.wildcard(ctx.cached <> ".part-*") == []
    end

    test "a checksum mismatch is an error and nothing is kept", ctx do
      serve(ctx.bypass, "tampered bytes")

      assert {:error, {:checksum_mismatch, source}} = Delivery.ensure()
      assert source =~ "/dl/" <> Artifact.file_name()
      refute File.exists?(ctx.cached)
      assert Path.wildcard(ctx.cached <> "*") == []
    end

    test "an HTTP error is a download failure", ctx do
      serve(ctx.bypass, "nope", 404)
      assert {:error, {:download_failed, why}} = Delivery.ensure()
      assert why =~ "HTTP 404"
    end

    test "an unreachable host is a download failure", ctx do
      Bypass.down(ctx.bypass)
      assert {:error, {:download_failed, _}} = Delivery.ensure()
    end

    test "a build without a pin cannot download, and does not try", ctx do
      Application.put_env(:mydia, :cardigann_pinned_sha256, nil)
      # Bypass fails the test on an unexpected request.
      assert {:error, :no_pin} = Delivery.ensure()
      refute File.exists?(ctx.cached)
      assert Delivery.describe(:no_pin) =~ "no pinned checksum"
    end
  end

  describe "resolution order" do
    test "a verified file in the data directory is used without the network", ctx do
      File.mkdir_p!(Path.dirname(ctx.cached))
      File.write!(ctx.cached, @bytes)

      # Bypass has no expectation: a request would fail the test.
      assert {:ok, path} = Delivery.ensure()
      assert path == ctx.cached
    end

    test "a corrupt file in the data directory is replaced by a fresh download", ctx do
      File.mkdir_p!(Path.dirname(ctx.cached))
      File.write!(ctx.cached, "truncated")
      serve(ctx.bypass, @bytes)

      assert {:ok, path} = Delivery.ensure()
      assert File.read!(path) == @bytes
    end

    test "CARDIGANN_WASM_PATH wins over the data directory and the network", ctx do
      File.mkdir_p!(Path.dirname(ctx.cached))
      File.write!(ctx.cached, @bytes)
      mirrored = Path.join(ctx.dir, "mirrored.wasm")
      File.write!(mirrored, @bytes)
      System.put_env("CARDIGANN_WASM_PATH", mirrored)

      assert {:ok, ^mirrored} = Delivery.ensure()
    end

    test "CARDIGANN_WASM_PATH is verified against the pin and never falls back", ctx do
      wrong = Path.join(ctx.dir, "wrong.wasm")
      File.write!(wrong, "some other build")
      System.put_env("CARDIGANN_WASM_PATH", wrong)

      # The data directory holds a good copy; it must not be used instead.
      File.mkdir_p!(Path.dirname(ctx.cached))
      File.write!(ctx.cached, @bytes)

      assert {:error, {:checksum_mismatch, source}} = Delivery.ensure()
      assert source =~ "CARDIGANN_WASM_PATH"
    end

    test "an unreadable CARDIGANN_WASM_PATH is an error", ctx do
      System.put_env("CARDIGANN_WASM_PATH", Path.join(ctx.dir, "absent.wasm"))
      assert {:error, {:env_path_unreadable, _}} = Delivery.ensure()
    end

    test "the development artifact with its sidecar comes first", ctx do
      dev = Path.join(ctx.dir, "dev.wasm")
      File.write!(dev, "a local build")
      File.write!(dev <> ".sha256", Artifact.sha256("a local build") <> "\n")
      Application.put_env(:mydia, :cardigann_wasm_path, dev)

      assert {:ok, ^dev} = Delivery.ensure()
    end
  end

  describe "prune/1" do
    test "removes other versions and keeps the current files and unrelated ones", ctx do
      dir = Path.dirname(ctx.cached)
      File.mkdir_p!(dir)

      keep = [Artifact.file_name(), Artifact.cwasm_name(), "unrelated.txt"]
      stale = ~w(
        cardigann-0000000000000000.wasm
        cardigann-0000000000000000-wasmtime1.0.0-x86_64.cwasm
        cardigann-#{Artifact.source_hash()}-wasmtime0.0.1-x86_64.cwasm
        cardigann-#{Artifact.source_hash()}-wasmtime1.0.0-riscv64.cwasm.part-1
      )

      for name <- keep ++ stale, do: File.write!(Path.join(dir, name), "x")

      removed = Delivery.prune(dir)

      assert Enum.sort(Enum.map(removed, &Path.basename/1)) == Enum.sort(stale)
      assert dir |> File.ls!() |> Enum.sort() == Enum.sort(keep)
    end

    test "a missing directory is nothing to prune", ctx do
      assert Delivery.prune(Path.join(ctx.dir, "never-created")) == []
    end
  end

  test "the cached component name carries the wasmtime version and the architecture" do
    assert Artifact.cwasm_name() =~
             ~r/\Acardigann-[0-9a-f]{16}-wasmtime\d+\.\d+\.\d+-[a-z0-9_]+\.cwasm\z/
  end
end
