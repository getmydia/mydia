defmodule MydiaWeb.StreamLinkTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.MediaFile
  alias MydiaWeb.StreamLink

  @file_id "6f1c1b7e-0000-4000-8000-000000000001"
  @user_id "6f1c1b7e-0000-4000-8000-000000000002"

  defp media_file(relative_path) do
    %MediaFile{id: @file_id, library_path: nil, relative_path: relative_path}
  end

  defp token_of(path) do
    ["", "stream", token, _name] = String.split(path, "/")
    token
  end

  test "path round-trips through verify to the user and file" do
    path = StreamLink.path(@user_id, media_file("Zephyr Station (2030)/Zephyr.Station.2030.mkv"))

    assert {:ok, {@user_id, @file_id}} = path |> token_of() |> StreamLink.verify()
  end

  test "path ends in the encoded basename" do
    path = StreamLink.path(@user_id, media_file("Emberline (2029)/Emberline 2029 [1080p].mkv"))

    assert String.ends_with?(path, "/Emberline%202029%20%5B1080p%5D.mkv")
  end

  test "a tampered token does not verify" do
    token = StreamLink.path(@user_id, media_file("a.mkv")) |> token_of()

    assert StreamLink.verify(token <> "x") == :error
    assert StreamLink.verify("garbage") == :error
  end
end
