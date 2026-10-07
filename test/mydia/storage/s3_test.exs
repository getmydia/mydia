defmodule Mydia.Storage.S3Test do
  use ExUnit.Case, async: true

  # Must precede the contract case: its tests are defined at `use` time and a
  # @moduletag only applies to tests defined after it.
  @moduletag :s3

  use Mydia.StorageContractCase

  setup do
    loc = Mydia.S3Helpers.unique_location(Mydia.S3Helpers.backend())
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
end
