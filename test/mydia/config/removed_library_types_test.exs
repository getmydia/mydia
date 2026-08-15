defmodule Mydia.Config.RemovedLibraryTypesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Mydia.Config.Schema

  defp library_path(attrs) do
    %Schema{}
    |> Schema.changeset(%{"library_paths" => [attrs]})
    |> Ecto.Changeset.apply_action(:insert)
  end

  test "a music library path is coerced to an unmonitored mixed library" do
    log =
      capture_log(fn ->
        assert {:ok, config} = library_path(%{"path" => "/media/music", "type" => "music"})
        assert [path] = config.library_paths
        assert path.type == :mixed
        assert path.monitored == false
      end)

    assert log =~ "/media/music"
  end

  test "books and adult are coerced the same way" do
    capture_log(fn ->
      assert {:ok, books} = library_path(%{"path" => "/media/books", "type" => "books"})
      assert [%{type: :mixed, monitored: false}] = books.library_paths

      assert {:ok, adult} = library_path(%{"path" => "/media/adult", "type" => "adult"})
      assert [%{type: :mixed, monitored: false}] = adult.library_paths
    end)
  end

  test "a supported type is left alone and logs nothing" do
    log =
      capture_log(fn ->
        assert {:ok, config} = library_path(%{"path" => "/media/movies", "type" => "movies"})
        assert [%{type: :movies, monitored: true}] = config.library_paths
      end)

    refute log =~ "no longer supports"
  end
end
