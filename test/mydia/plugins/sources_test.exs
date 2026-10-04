defmodule Mydia.Plugins.SourcesTest do
  use Mydia.DataCase, async: true

  import Mydia.MinisignFixtures

  alias Mydia.Plugins.PluginSource
  alias Mydia.Plugins.Sources
  alias Mydia.Settings.PluginConfig

  defp add!(url \\ "https://plugins.example.test/index.json") do
    {:ok, source} = Sources.add_source(%{url: url, public_key: keypair().public, name: "Example"})
    source
  end

  test "add_source pins the key and derives its fingerprint" do
    source = add!()
    assert source.key_id =~ ~r/^[0-9A-F]{16}$/
    refute source.declared
  end

  test "add_source refuses http, a bad key and a duplicate URL" do
    assert {:error, cs} =
             Sources.add_source(%{url: "http://x.test/i.json", public_key: keypair().public})

    assert %{url: [_]} = errors_on(cs)
    assert {:error, cs} = Sources.add_source(%{url: "https://x.test/i.json", public_key: "nope"})
    assert %{public_key: [_]} = errors_on(cs)
    add!("https://dup.test/i.json")

    assert {:error, cs} =
             Sources.add_source(%{url: "https://dup.test/i.json", public_key: keypair().public})

    assert %{url: [_]} = errors_on(cs)
  end

  test "remove_source refuses a declared row and nulls installs of a removed one" do
    source = add!()

    {:ok, config} =
      Mydia.Settings.create_plugin_config(%{
        slug: "fixture-tool",
        name: "Fixture Tool",
        source_url: "https://plugins.example.test/p.wasm",
        plugin_source_id: source.id
      })

    declared = source |> Ecto.Changeset.change(declared: true) |> Repo.update!()
    assert {:error, :declared} = Sources.remove_source(declared)

    assert {:ok, _} = Sources.remove_source(source)
    assert Repo.reload!(config).plugin_source_id == nil
  end

  test "record_fetch stores success and failure on the row" do
    source = add!()
    :ok = Sources.record_fetch(source.id, {:ok, %{name: "Renamed", plugin_count: 3}})

    assert %PluginSource{name: "Renamed", plugin_count: 3, last_error: nil} =
             Repo.reload!(source)

    :ok = Sources.record_fetch(source.id, {:error, "signing key changed"})

    assert %PluginSource{last_error: "signing key changed", plugin_count: 3} =
             Repo.reload!(source)

    assert :ok = Sources.record_fetch(nil, {:error, "ignored for the official index"})
  end

  describe "origin/1" do
    test "derives where an installed plugin came from" do
      id = Ecto.UUID.generate()
      assert Sources.origin(%PluginConfig{source_url: "bundled"}) == :bundled
      assert Sources.origin(%PluginConfig{source_url: "file:///tmp/p.wasm"}) == :sideloaded

      assert Sources.origin(%PluginConfig{
               source_url: "https://x.test/p.wasm",
               plugin_source_id: id
             }) ==
               {:source, id}

      assert Sources.origin(%PluginConfig{
               source_url: "https://plugins.mydia.dev/packages/p/1.0.0.wasm"
             }) == :official

      assert Sources.origin(%PluginConfig{source_url: "https://gone.test/p.wasm"}) == :removed
      assert Sources.origin(%PluginConfig{source_url: nil}) == :removed
    end
  end
end
