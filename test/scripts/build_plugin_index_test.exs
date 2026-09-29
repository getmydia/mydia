defmodule Mydia.Scripts.BuildPluginIndexTest do
  # Runs the real script in a child `elixir` process, then parses its output
  # with the same module Mydia uses to read a live catalog.
  use ExUnit.Case, async: true

  alias Mydia.Plugins.Manifest

  @script Path.expand("../../scripts/build_plugin_index.exs", __DIR__)

  @manifest %{
    "slug" => "echo-panel",
    "name" => "Echo Panel",
    "version" => "0.3.1",
    "description" => "Echoes things",
    "author" => "Mydia",
    "capabilities" => %{
      "events:subscribe" => ["media_item.added"],
      "net:http" => ["example.com"]
    }
  }

  setup do
    root = Path.join(System.tmp_dir!(), "plugin-index-#{System.unique_integer([:positive])}")
    crates = Path.join(root, "crates")
    wasm_dir = Path.join(root, "wasm")
    out = Path.join(root, "site")

    File.mkdir_p!(Path.join(crates, "echo_panel"))
    File.mkdir_p!(wasm_dir)
    File.write!(Path.join([crates, "echo_panel", "manifest.json"]), Jason.encode!(@manifest))

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, crates: crates, wasm_dir: wasm_dir, out: out}
  end

  defp run(args), do: System.cmd("elixir", [@script | args], stderr_to_stdout: true)

  test "writes an index Mydia can parse and copies the package", ctx do
    bytes = "\0asm fake component bytes"
    File.write!(Path.join(ctx.wasm_dir, "echo_panel.wasm"), bytes)

    {output, 0} =
      run([
        "--crates-dir",
        ctx.crates,
        "--wasm-dir",
        ctx.wasm_dir,
        "--out",
        ctx.out,
        "--base-url",
        "https://plugins.example.test/"
      ])

    assert output =~ "wrote 1 plugin(s)"

    index = ctx.out |> Path.join("index.json") |> File.read!() |> Jason.decode!()
    assert index["version"] == 1
    assert [entry] = index["plugins"]

    assert entry["package_url"] ==
             "https://plugins.example.test/packages/echo-panel/0.3.1.wasm"

    hex = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    assert entry["integrity"] == "sha256:" <> hex
    assert entry["name"] == "Echo Panel"
    assert {:ok, %Manifest{slug: "echo-panel"}} = Manifest.parse(entry["manifest"])

    assert File.read!(Path.join([ctx.out, "packages", "echo-panel", "0.3.1.wasm"])) == bytes
  end

  test "fails loudly when a crate has no built wasm", ctx do
    {output, status} =
      run(["--crates-dir", ctx.crates, "--wasm-dir", ctx.wasm_dir, "--out", ctx.out])

    assert status != 0
    assert output =~ "echo_panel.wasm"
  end

  test "writes an empty index when there are no crates", ctx do
    empty = Path.join([ctx.out, "..", "empty"]) |> Path.expand()
    File.mkdir_p!(empty)

    {_output, 0} =
      run(["--crates-dir", empty, "--wasm-dir", ctx.wasm_dir, "--out", ctx.out])

    assert %{"version" => 1, "plugins" => []} =
             ctx.out |> Path.join("index.json") |> File.read!() |> Jason.decode!()
  end
end
