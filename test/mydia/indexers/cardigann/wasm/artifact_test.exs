defmodule Mydia.Indexers.Cardigann.Wasm.ArtifactTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.Wasm.{Artifact, SourceHash}

  @repo_root Path.expand("../../../../..", __DIR__)

  test "source_hash is stable and covers the pin files" do
    assert Artifact.source_hash() =~ ~r/^[0-9a-f]{16}$/
    assert Artifact.source_hash() == Artifact.source_hash()
  end

  test "tracked_files covers pins and excludes build output and docs" do
    files = Artifact.tracked_files()
    assert "native/cardigann_guest/PROWLARR_REF" in files
    assert "native/cardigann_guest/vendor-files.txt" in files
    assert "native/cardigann_guest/deny/Cargo.lock" in files
    refute Enum.any?(files, &String.contains?(&1, ".prowlarr/"))
    refute Enum.any?(files, &String.contains?(&1, "/out/"))
    refute Enum.any?(files, &String.ends_with?(&1, ".md"))
    refute "native/cardigann_guest/ARTIFACT_SHA256" in files
  end

  test "excluded patterns" do
    for f <- [
          "native/cardigann_guest/SPIKE.md",
          "native/cardigann_guest/ARTIFACT_SHA256",
          "native/cardigann_guest/deny/target/x.rs",
          "native/cardigann_guest/deny/gen/stubs.rs",
          "native/cardigann_guest/out/cardigann.wasm",
          "native/cardigann_guest/obj/a",
          "native/cardigann_guest/bin/a"
        ] do
      assert SourceHash.excluded?(f), f
    end

    refute SourceHash.excluded?("native/cardigann_guest/PROWLARR_REF")
    refute SourceHash.excluded?("native/cardigann_guest/shim/Services.cs")
  end

  test "walking the directory gives the same file list as git" do
    assert SourceHash.tracked_files(:walk) == SourceHash.tracked_files(:git)
  end

  test "source_hash matches the CI shell pipeline" do
    {out, 0} =
      System.cmd("bash", ["native/cardigann_guest/scripts/source-hash.sh"], cd: @repo_root)

    assert String.trim(out) == Artifact.source_hash()
  end

  test "doc edits do not change the hash, source edits do" do
    dir = Path.join(System.tmp_dir!(), "artifact-hash-#{System.unique_integer([:positive])}")
    guest = Path.join(dir, "native/cardigann_guest")
    File.mkdir_p!(guest)
    on_exit(fn -> File.rm_rf!(dir) end)
    File.write!(Path.join(guest, "PROWLARR_REF"), "v1 abc\n")
    File.write!(Path.join(guest, "README.md"), "one")
    File.write!(Path.join(guest, "ARTIFACT_SHA256"), "x y")

    before = SourceHash.source_hash(:walk, dir)
    File.write!(Path.join(guest, "README.md"), "two")
    File.write!(Path.join(guest, "ARTIFACT_SHA256"), "z w")
    assert SourceHash.source_hash(:walk, dir) == before
    File.write!(Path.join(guest, "PROWLARR_REF"), "v2 abc\n")
    refute SourceHash.source_hash(:walk, dir) == before
  end

  test "load verifies the checksum" do
    dir = Path.join(System.tmp_dir!(), "artifact-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    wasm = Path.join(dir, "x.wasm")
    File.write!(wasm, "not really wasm")
    File.write!(wasm <> ".sha256", String.duplicate("0", 64))

    assert {:error, :checksum_mismatch} = Artifact.load(wasm)

    File.write!(
      wasm <> ".sha256",
      :crypto.hash(:sha256, "not really wasm") |> Base.encode16(case: :lower)
    )

    assert {:ok, "not really wasm"} = Artifact.load(wasm)
    assert {:error, :missing} = Artifact.load(Path.join(dir, "absent.wasm"))
  end

  test "path is named by the source hash" do
    assert Path.basename(Artifact.path()) == "cardigann-#{Artifact.source_hash()}.wasm"
  end

  test "version reads the Prowlarr tag" do
    assert %{prowlarr_tag: "v2.6.5.5623", hash: hash} = Artifact.version()
    assert hash == Artifact.source_hash()
  end
end
