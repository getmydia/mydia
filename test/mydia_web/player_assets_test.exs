defmodule MydiaWeb.PlayerAssetsTest do
  use ExUnit.Case, async: true

  alias MydiaWeb.PlayerAssets

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    {:ok, bundle: Path.join(tmp_dir, "main.dart.js")}
  end

  describe "etag/1" do
    test "survives the mtime churn a redeploy inflicts on unchanged bytes", %{bundle: bundle} do
      File.write!(bundle, "console.log('unchanged');")
      before = PlayerAssets.etag(bundle)

      # What shipping a new container image does to every file in the tree,
      # including the canvaskit blobs nobody touched. The default
      # phash2({size, mtime}) validator changes here; a content hash must not.
      File.touch!(bundle, System.os_time(:second) + 60)

      assert PlayerAssets.etag(bundle) == before
    end

    test "changes when the bundle actually changes", %{bundle: bundle} do
      File.write!(bundle, "console.log('old build');")
      before = PlayerAssets.etag(bundle)

      File.write!(bundle, "console.log('new build');")

      refute PlayerAssets.etag(bundle) == before
    end

    test "notices a same-second rewrite that keeps the byte count identical", %{bundle: bundle} do
      File.write!(bundle, "aaaa")
      before = PlayerAssets.etag(bundle)

      # Same size, same second, so {size, mtime} reads as unchanged. Only the
      # settle window saves this from serving a stale validator.
      File.write!(bundle, "bbbb")

      refute PlayerAssets.etag(bundle) == before
    end

    test "reuses the memo once the file has settled", %{bundle: bundle} do
      File.write!(bundle, "console.log('settled');")
      File.touch!(bundle, System.os_time(:second) - 3600)

      first = PlayerAssets.etag(bundle)

      # Corrupting the bytes without moving size or mtime is the only way to
      # observe the memo from outside. A second call must not re-read.
      File.write!(bundle, "console.log('CORRUPT');")
      File.touch!(bundle, System.os_time(:second) - 3600)

      assert PlayerAssets.etag(bundle) == first
    end

    test "is quoted, since Plug.Static sends it as the header verbatim", %{bundle: bundle} do
      File.write!(bundle, "console.log('bundle');")

      etag = PlayerAssets.etag(bundle)

      assert <<?", _rest::binary>> = etag
      assert String.ends_with?(etag, "\"")
    end

    test "yields a validator that cannot match when the file is gone", %{bundle: bundle} do
      refute File.exists?(bundle)

      assert PlayerAssets.etag(bundle) != PlayerAssets.etag(bundle)
    end
  end
end
