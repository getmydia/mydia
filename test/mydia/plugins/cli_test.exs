defmodule Mydia.Plugins.CLITest do
  use Mydia.DataCase, async: false

  import ExUnit.CaptureIO

  alias Mydia.Plugins.CLI
  alias Mydia.Settings

  @guest_fixture Path.join([
                   __DIR__,
                   "..",
                   "..",
                   "support",
                   "fixtures",
                   "plugins",
                   "host_test_fixture.wasm"
                 ])

  setup do
    original_runtime = Application.get_env(:mydia, :runtime_config)

    on_exit(fn ->
      if original_runtime do
        Application.put_env(:mydia, :runtime_config, original_runtime)
      else
        Application.delete_env(:mydia, :runtime_config)
      end
    end)
  end

  @tag :tmp_dir
  test "install sideloads a plugin inactive", %{tmp_dir: dir} do
    manifest_path = Path.join(dir, "manifest.json")

    File.write!(
      manifest_path,
      Jason.encode!(%{
        "slug" => "cli-fixture",
        "name" => "CLI Fixture",
        "version" => "1.0.0",
        "capabilities" => %{"events:subscribe" => ["media_item.added"]}
      })
    )

    output =
      capture_io(fn ->
        assert :ok = CLI.run(["install", Path.expand(@guest_fixture), manifest_path])
      end)

    assert output =~ "Installed inactive"
    refute Settings.get_plugin_config_by_slug("cli-fixture").enabled
  end

  test "rejects a malformed command" do
    capture_io(:stderr, fn ->
      assert {:error, "invalid arguments"} = CLI.run(["install", "only-one-path"])
      assert {:error, "invalid arguments"} = CLI.run(["frobnicate"])
    end)
  end

  test "run!/1 raises on failure so the rpc client exits non-zero" do
    capture_io(:stderr, fn ->
      assert_raise RuntimeError, ~r/invalid arguments/, fn -> CLI.run!(["frobnicate"]) end
    end)
  end
end
