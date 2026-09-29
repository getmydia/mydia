defmodule Mydia.Plugins.ExtraManifestsTest do
  # The publish workflow builds the index without compiling Mydia, so manifest
  # validity for plugins-extra/ is enforced here, where every PR runs it.
  use ExUnit.Case, async: true

  @root Path.expand("../../../plugins-extra", __DIR__)

  for path <- Path.wildcard(Path.join(@root, "*/manifest.json")) do
    @path path
    test "#{Path.relative_to(path, @root)} parses and matches its crate" do
      json = File.read!(@path)
      assert {:ok, %Mydia.Plugins.Manifest{} = manifest} = Mydia.Plugins.Manifest.parse(json)

      crate = @path |> Path.dirname() |> Path.basename()
      cargo = File.read!(Path.join(Path.dirname(@path), "Cargo.toml"))
      assert cargo =~ ~s(name = "#{crate}"), "Cargo package name must equal the directory name"
      assert manifest.version =~ ~r/^\d+\.\d+\.\d+/
    end
  end

  test "plugins-extra exists" do
    assert File.dir?(@root)
  end
end
