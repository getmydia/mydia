defmodule Mydia.Config.PluginSourcesConfigTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mydia.MinisignFixtures

  alias Mydia.Config.Loader

  @yaml_path Path.join(
               System.tmp_dir!(),
               "plugin_sources_#{System.unique_integer([:positive])}.yml"
             )

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Mydia.Repo, shared: true)
    clear_env()
    erase_warnings()

    on_exit(fn ->
      File.rm(@yaml_path)
      clear_env()
      erase_warnings()
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
    end)

    :ok
  end

  defp clear_env do
    for {k, _} <- System.get_env(),
        String.starts_with?(k, "PLUGINS_SOURCE_"),
        do: System.delete_env(k)
  end

  defp erase_warnings do
    for {{Loader, :warned, _} = key, _} <- :persistent_term.get(),
        do: :persistent_term.erase(key)
  end

  defp load_env, do: Loader.load(config_file: "nonexistent.yml", sources: [:env])

  test "PLUGINS_SOURCE_<N>_* declares sources in index order" do
    a = keypair().public
    b = keypair().public
    System.put_env("PLUGINS_SOURCE_1_URL", "https://b.test/index.json")
    System.put_env("PLUGINS_SOURCE_1_PUBLIC_KEY", b)
    System.put_env("PLUGINS_SOURCE_0_URL", "https://a.test/index.json")
    System.put_env("PLUGINS_SOURCE_0_PUBLIC_KEY", a)

    assert {:ok, config} = load_env()

    assert [
             %{url: "https://a.test/index.json", public_key: ^a},
             %{url: "https://b.test/index.json"}
           ] = config.plugin_sources

    assert config.plugin_instances == []
  end

  test "a declared source without a key, or over http, is a config error" do
    System.put_env("PLUGINS_SOURCE_0_URL", "https://a.test/index.json")
    assert {:error, %Ecto.Changeset{}} = load_env()

    System.put_env("PLUGINS_SOURCE_0_URL", "http://a.test/index.json")
    System.put_env("PLUGINS_SOURCE_0_PUBLIC_KEY", keypair().public)
    assert {:error, %Ecto.Changeset{}} = load_env()
  end

  test "YAML plugin_sources parse" do
    key = keypair().public

    File.write!(
      @yaml_path,
      "plugin_sources:\n  - url: https://a.test/index.json\n    public_key: #{key}\n"
    )

    assert {:ok, config} = Loader.load(config_file: @yaml_path, sources: [:yaml])
    assert [%{url: "https://a.test/index.json", public_key: ^key}] = config.plugin_sources
  end

  test "overriding index_url requires index_public_key" do
    File.write!(@yaml_path, "plugins:\n  index_url: https://staging.test/index.json\n")
    assert {:error, %Ecto.Changeset{}} = Loader.load(config_file: @yaml_path, sources: [:yaml])

    File.write!(
      @yaml_path,
      "plugins:\n  index_url: https://staging.test/index.json\n  index_public_key: #{keypair().public}\n"
    )

    assert {:ok, _} = Loader.load(config_file: @yaml_path, sources: [:yaml])
  end

  test "extra_source_urls is ignored with a warning" do
    File.write!(@yaml_path, "plugins:\n  extra_source_urls:\n    - https://old.test/index.json\n")

    log =
      capture_log(fn ->
        assert {:ok, config} = Loader.load(config_file: @yaml_path, sources: [:yaml])
        refute Map.has_key?(config.plugins, :extra_source_urls)
      end)

    assert log =~ "extra_source_urls"
  end
end
