defmodule Mydia.Storage.S3Test do
  # Storage.at/1 resolves s3:// paths through the storage_backends table.
  use Mydia.DataCase, async: false

  # Must precede the contract case: its tests are defined at `use` time and a
  # @moduletag only applies to tests defined after it.
  @moduletag :s3
  @moduletag :tmp_dir

  use Mydia.StorageContractCase

  setup do
    loc = Mydia.S3Helpers.unique_location(Mydia.S3Helpers.ensure_backend_row!())
    on_exit(fn -> Mydia.S3Helpers.delete_prefix!(loc) end)
    %{location: loc}
  end

  def put_fixture(%{location: loc}, rel, bin), do: Mydia.S3Helpers.put_object!(loc, rel, bin)

  test "keys with spaces and parentheses round-trip", %{location: loc} = ctx do
    put_fixture(ctx, "Invented Film (2031)/Invented Film (2031) [1080p].mkv", "z")

    {:ok, src} =
      Mydia.Storage.source(loc, "Invented Film (2031)/Invented Film (2031) [1080p].mkv")

    assert {:ok, %{size: 1}} = Mydia.Storage.stat(src)
    assert {:ok, url} = Mydia.Storage.input(src)
    assert {:ok, %{status: 200, body: "z"}} = Req.get(url)
  end

  @mib 1024 * 1024

  test "a file above the part size is uploaded in parts and copied in parts",
       %{location: loc} = ctx do
    path = Path.join(ctx.tmp_dir, "big.mkv")
    body = :crypto.strong_rand_bytes(11 * @mib)
    File.write!(path, body)

    {:ok, dest} = Mydia.Storage.source(loc, "Invented Film (2031)/big.mkv")
    assert :ok = Mydia.Storage.put_file(dest, path, part_size: 5 * @mib)
    assert {:ok, ^body} = Mydia.Storage.read(dest)

    # config/test.exs sets copy_threshold below 11 MiB, so this is UploadPartCopy.
    {:ok, copy} = Mydia.Storage.source(loc, "Invented Film (2031)/copy.mkv")
    assert :ok = Mydia.Storage.copy(dest, copy)
    assert {:ok, ^body} = Mydia.Storage.read(copy)
  end
end
