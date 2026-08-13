defmodule MydiaWeb.PlayerAssetsTest do
  use ExUnit.Case, async: true

  alias MydiaWeb.PlayerAssets

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    {:ok, bundle: Path.join(tmp_dir, "main.dart.js")}
  end

  # A deploy stamps mtimes from the clock of whatever built the image, which
  # may land either side of the clock on the host serving it.
  defp stamp(bundle, offset), do: File.touch!(bundle, System.os_time(:second) + offset)

  defp memo(bundle), do: :persistent_term.get({PlayerAssets, bundle}, :absent)

  describe "etag/1" do
    test "survives the mtime churn a redeploy inflicts on unchanged bytes", %{bundle: bundle} do
      File.write!(bundle, "console.log('unchanged');")
      stamp(bundle, -3600)
      before = PlayerAssets.etag(bundle)

      # What shipping a new container image does to every file in the tree,
      # including the canvaskit blobs nobody touched. The default
      # phash2({size, mtime}) validator changes here; a content hash must not.
      stamp(bundle, -60)

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
      settled = System.os_time(:second) - 3600
      File.touch!(bundle, settled)

      first = PlayerAssets.etag(bundle)

      # Corrupting the bytes without moving size or mtime is the only way to
      # observe the memo from outside. A second call must not re-read. Both
      # touches carry the same literal timestamp, so the memo key cannot drift
      # across a second boundary mid-test.
      File.write!(bundle, "console.log('CORRUPT');")
      File.touch!(bundle, settled)

      assert PlayerAssets.etag(bundle) == first
    end

    test "memoizes a file dated in the future rather than re-hashing forever", %{bundle: bundle} do
      # A host whose clock trails the machine that built the image sees every
      # asset in the tree dated ahead of now. Reading that as "still settling"
      # would strand the whole player outside the memo, turning each request
      # for a multi-megabyte bundle into a full read and hash.
      File.write!(bundle, "console.log('future');")
      stamp(bundle, 3600)

      assert PlayerAssets.etag(bundle)

      assert {_size, _mtime, _etag} = memo(bundle)
    end

    test "does not memoize a file that is still settling", %{bundle: bundle} do
      File.write!(bundle, "console.log('just written');")

      assert PlayerAssets.etag(bundle)

      assert memo(bundle) == :absent
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
