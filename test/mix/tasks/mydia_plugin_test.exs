defmodule Mix.Tasks.Mydia.PluginTest do
  use Mydia.DataCase, async: false

  import ExUnit.CaptureIO

  alias Mydia.Settings

  @guest_fixture Path.expand("../../support/fixtures/plugins/host_test_fixture.wasm", __DIR__)

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
        "slug" => "mix-fixture",
        "name" => "Mix Fixture",
        "version" => "1.0.0",
        "capabilities" => %{"events:subscribe" => ["media_item.added"]}
      })
    )

    output =
      capture_io(fn ->
        Mix.Tasks.Mydia.Plugin.run(["install", @guest_fixture, manifest_path])
      end)

    assert output =~ "Installed inactive"
    refute Settings.get_plugin_config_by_slug("mix-fixture").enabled
  end

  test "bad arguments raise so the shell exits non-zero" do
    capture_io(:stderr, fn ->
      assert_raise Mix.Error, ~r/invalid arguments/, fn ->
        Mix.Tasks.Mydia.Plugin.run(["install", "only-one-path"])
      end
    end)
  end
end
