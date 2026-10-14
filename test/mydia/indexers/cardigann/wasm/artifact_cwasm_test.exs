defmodule Mydia.Indexers.Cardigann.Wasm.ArtifactCwasmTest do
  # Not async: the pin test changes application env.
  use ExUnit.Case, async: false

  alias Mydia.Indexers.Cardigann.Wasm.Artifact

  describe "published .cwasm" do
    test "the release and asset carry the guest hash, wasmtime version, config version and arch" do
      tag = Artifact.cwasm_release_tag()
      asset = Artifact.cwasm_asset_name()
      hash = Artifact.source_hash()
      wt = Artifact.wasmtime_version()
      cfg = Artifact.cwasm_config_version()

      assert tag == "cardigann-cwasm-#{hash}-wasmtime#{wt}-cfg#{cfg}"
      assert asset == "cardigann-#{hash}-wasmtime#{wt}-cfg#{cfg}-#{Artifact.arch()}.cwasm.gz"
      assert Artifact.arch() in ["x86_64", "aarch64"]
      assert String.ends_with?(Artifact.cwasm_base_url(), "/releases/download/" <> tag)
    end

    test "the config version moves with the engine configs" do
      # A .cwasm loads only into an engine configured like the one that wrote
      # it. If this fails because a config changed, bump @cwasm_config_version
      # in Artifact and update both literals here.
      alias Mydia.Indexers.Cardigann.Wasm.EngineConfig

      assert Artifact.cwasm_config_version() == 1

      assert EngineConfig.ci_config() ==
               %Wasmex.EngineConfig{isa_baseline: true}
    end

    test "the pin is read from the baked sidecar named after the asset, and only a SHA-256 counts" do
      dir = Path.join(System.tmp_dir!(), "cwasm-pin-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      Application.put_env(:mydia, :cardigann_wasm_path, Path.join(dir, Artifact.file_name()))

      on_exit(fn ->
        Application.delete_env(:mydia, :cardigann_wasm_path)
        File.rm_rf!(dir)
      end)

      assert Artifact.cwasm_pin() == nil
      File.write!(Artifact.cwasm_pin_path(), "not a sha\n")
      assert Artifact.cwasm_pin() == nil
      sha = String.duplicate("a", 64)
      File.write!(Artifact.cwasm_pin_path(), sha <> "\n")
      assert Artifact.cwasm_pin() == sha

      assert Path.basename(Artifact.cwasm_pin_path()) ==
               String.replace_suffix(Artifact.cwasm_asset_name(), ".gz", ".sha256")
    end
  end
end
