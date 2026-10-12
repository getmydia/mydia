defmodule Mix.Tasks.Mydia.CardigannGuestTest do
  # Mutates :mydia application env (restored in on_exit), so not async.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Mydia.CardigannGuest, as: Task
  alias Mydia.Indexers.Cardigann.Wasm.Artifact

  @keys [:cardigann_guest_base_url, :cardigann_guest_dir, :cardigann_guest_local]

  setup do
    bypass = Bypass.open()
    dir = Path.join(System.tmp_dir!(), "cg-task-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    prior = for k <- @keys, do: {k, Application.fetch_env(:mydia, k)}

    Application.put_env(:mydia, :cardigann_guest_base_url, "http://localhost:#{bypass.port}/dl")
    Application.put_env(:mydia, :cardigann_guest_dir, dir)
    Application.put_env(:mydia, :cardigann_guest_local, Path.join(dir, "no-local.wasm"))

    on_exit(fn ->
      for {k, v} <- prior do
        case v do
          {:ok, val} -> Application.put_env(:mydia, k, val)
          :error -> Application.delete_env(:mydia, k)
        end
      end

      File.rm_rf!(dir)
    end)

    %{bypass: bypass, dir: dir, wasm: Path.join(dir, Artifact.file_name())}
  end

  defp sha(bin), do: :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)

  # Runs fun with the task's stderr warning swallowed and returns its result.
  defp quiet(fun) do
    parent = self()
    ref = make_ref()
    ExUnit.CaptureIO.capture_io(:stderr, fn -> send(parent, {ref, fun.()}) end)

    receive do
      {^ref, result} -> result
    end
  end

  defp serve(bypass, name, body) do
    Bypass.expect(bypass, "GET", "/dl/#{name}", fn conn -> Plug.Conn.resp(conn, 200, body) end)
  end

  test "fetch downloads and verifies", %{bypass: bypass, wasm: wasm} do
    name = Path.basename(wasm)
    serve(bypass, name, "wasm-bytes")
    serve(bypass, name <> ".sha256", sha("wasm-bytes") <> "\n")

    assert :ok = Task.fetch()
    assert {:ok, "wasm-bytes"} = Artifact.load(wasm)
  end

  test "fetch is a no-op when the file already verifies", %{bypass: bypass, wasm: wasm} do
    File.write!(wasm, "have")
    File.write!(wasm <> ".sha256", sha("have"))
    Bypass.down(bypass)
    assert :ok = Task.fetch()
    assert {:ok, "have"} = Artifact.load(wasm)
  end

  test "fetch rejects a download whose checksum is wrong", %{bypass: bypass, wasm: wasm} do
    name = Path.basename(wasm)
    serve(bypass, name, "tampered")
    serve(bypass, name <> ".sha256", sha("original"))

    assert {:error, :checksum_mismatch} = Task.fetch()
    refute File.exists?(wasm)
  end

  test "fetch falls back to the local build on 404", %{bypass: bypass, dir: dir, wasm: wasm} do
    Bypass.expect(bypass, fn conn -> Plug.Conn.resp(conn, 404, "nope") end)
    local = Path.join(dir, "local.wasm")
    File.write!(local, "local-build")
    Application.put_env(:mydia, :cardigann_guest_local, local)

    assert :ok = Task.fetch()
    assert {:ok, "local-build"} = Artifact.load(wasm)
  end

  test "fetch is a soft failure when nothing is available", %{bypass: bypass, wasm: wasm} do
    Bypass.expect(bypass, fn conn -> Plug.Conn.resp(conn, 404, "nope") end)
    assert {:unavailable, _} = quiet(&Task.fetch/0)
    refute File.exists?(wasm)
  end

  test "fetch is a soft failure when the host is unreachable", %{bypass: bypass} do
    Bypass.down(bypass)
    assert {:unavailable, _} = quiet(&Task.fetch/0)
  end

  test "verify distinguishes missing, bad and good", %{wasm: wasm} do
    assert {:error, :missing} = Task.verify(false)
    assert :ok = Task.verify(true)

    File.write!(wasm, "x")
    File.write!(wasm <> ".sha256", String.duplicate("0", 64))
    assert {:error, :checksum_mismatch} = Task.verify(true)
    assert {:error, :checksum_mismatch} = Task.verify(false)

    File.write!(wasm <> ".sha256", sha("x"))
    assert :ok = Task.verify(false)
  end

  describe "compile step" do
    alias Mix.Tasks.Compile.CardigannGuest, as: Compiler

    test "logs a checksum mismatch loudly", %{bypass: bypass, wasm: wasm} do
      name = Path.basename(wasm)
      serve(bypass, name, "tampered")
      serve(bypass, name <> ".sha256", sha("original"))

      err = ExUnit.CaptureIO.capture_io(:stderr, fn -> Compiler.fetch_and_report() end)
      assert err =~ "failed verification"
      assert err =~ "checksum_mismatch"
      refute File.exists?(wasm)
    end

    test "remembers an unavailable asset and skips the network", %{bypass: bypass, dir: dir} do
      Bypass.expect(bypass, fn conn -> Plug.Conn.resp(conn, 404, "nope") end)
      quiet(&Compiler.fetch_and_report/0)
      assert [_marker] = Path.wildcard(Path.join(dir, ".unavailable-*"), match_dot: true)

      Bypass.down(bypass)
      assert :cached_unavailable = Compiler.fetch_and_report()
    end

    test "an expired marker is probed again", %{bypass: bypass, dir: dir, wasm: wasm} do
      [] = Path.wildcard(Path.join(dir, ".unavailable-*"), match_dot: true)
      stale = Path.join(dir, ".unavailable-#{Artifact.source_hash()}")
      File.write!(stale, "#{System.os_time(:second) - 7200}\n")

      name = Path.basename(wasm)
      serve(bypass, name, "ok")
      serve(bypass, name <> ".sha256", sha("ok"))
      assert :ok = Compiler.fetch_and_report()
      assert {:ok, "ok"} = Artifact.load(wasm)
    end
  end

  describe "pin" do
    setup do
      Application.put_env(:mydia, :cardigann_compiled_pin, nil)
      on_exit(fn -> Application.delete_env(:mydia, :cardigann_compiled_pin) end)
    end

    test "records the published checksum without fetching the guest", %{
      bypass: bypass,
      wasm: wasm
    } do
      # Only the sidecar is served: a request for the guest would fail the test.
      serve(bypass, Path.basename(wasm) <> ".sha256", sha("published") <> "\n")

      assert :ok = Task.pin(true)
      assert File.read!(wasm <> ".sha256") == sha("published") <> "\n"
      refute File.exists?(wasm)
    end

    test "an unpublished guest is a warning, and an error with --require", %{
      bypass: bypass,
      wasm: wasm
    } do
      Bypass.expect(bypass, fn conn -> Plug.Conn.resp(conn, 404, "") end)

      assert :ok = quiet(fn -> Task.pin(false) end)
      assert {:error, why} = Task.pin(true)
      assert why =~ "no published checksum"
      refute File.exists?(wasm <> ".sha256")
    end

    test "something that is not a checksum is not recorded", %{bypass: bypass, wasm: wasm} do
      serve(bypass, Path.basename(wasm) <> ".sha256", "<html>nope</html>")

      assert {:error, _} = Task.pin(true)
      refute File.exists?(wasm <> ".sha256")
    end

    test "nothing to do when ARTIFACT_SHA256 already pins these sources", %{wasm: wasm} do
      Application.put_env(:mydia, :cardigann_compiled_pin, String.duplicate("c", 64))

      # No server expectation: any request fails the test.
      assert :ok = Task.pin(true)
      refute File.exists?(wasm <> ".sha256")
    end
  end
end
