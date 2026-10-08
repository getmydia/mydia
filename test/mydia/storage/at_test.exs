defmodule Mydia.Storage.AtTest do
  use Mydia.DataCase, async: true

  test "at/1 reports an unknown backend and an empty key as misconfigured" do
    assert {:error, %Mydia.Storage.Error{kind: :misconfigured}} =
             Mydia.Storage.at("s3://nobody/movies/x.mkv")

    assert {:error, %Mydia.Storage.Error{kind: :misconfigured}} = Mydia.Storage.at("s3://m")
  end

  test "MediaFile.storage_path/1 is the stored path for both kinds" do
    alias Mydia.Library.MediaFile
    alias Mydia.Settings.LibraryPath

    assert MediaFile.storage_path(%MediaFile{
             relative_path: "A/a.mkv",
             library_path: %LibraryPath{path: "/media/movies"}
           }) == "/media/movies/A/a.mkv"

    assert MediaFile.storage_path(%MediaFile{
             relative_path: "A/a.mkv",
             library_path: %LibraryPath{path: "s3://m/movies"}
           }) == "s3://m/movies/A/a.mkv"

    assert MediaFile.storage_path(%MediaFile{relative_path: "A/a.mkv"}) == nil
  end
end
