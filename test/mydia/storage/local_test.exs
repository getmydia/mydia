defmodule Mydia.Storage.LocalTest do
  use ExUnit.Case, async: true
  use Mydia.StorageContractCase

  alias Mydia.Storage.Location

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    %{location: Location.local(dir), root: dir}
  end

  def put_fixture(%{root: root}, rel, bin) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bin)
  end

  test "input/1 is the absolute path", %{location: loc, root: root} = ctx do
    put_fixture(ctx, "x.mkv", "1")
    {:ok, source} = Mydia.Storage.source(loc, "x.mkv")
    assert {:ok, path} = Mydia.Storage.input(source)
    assert path == Path.join(root, "x.mkv")
  end

  test "validate/1 maps a missing root to :not_found" do
    assert {:error, %Mydia.Storage.Error{kind: :not_found}} =
             Mydia.Storage.validate(Location.local("/definitely/not/here"))
  end
end
