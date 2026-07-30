defmodule Mydia.Library.LibraryPathSyncTest do
  use Mydia.DataCase, async: false

  alias Mydia.Library.LibraryPathSync
  alias Mydia.Repo
  alias Mydia.Settings.LibraryPath

  # Builds the in-memory struct shape that Settings.get_runtime_library_paths/0
  # returns for an env/YAML configured path. The "runtime::" id prefix is what
  # LibraryPathSync.is_runtime_path?/1 keys on.
  defp runtime_path(path, attrs \\ %{}) do
    struct(
      %LibraryPath{
        id: "runtime::library_path::#{path}",
        path: path,
        type: :movies,
        monitored: true,
        scan_interval: nil
      },
      attrs
    )
  end

  defp sync!(runtime_paths) do
    LibraryPathSync.upsert_runtime_paths(runtime_paths)
  end

  describe "scan_interval layering" do
    test "preserves a DB-set interval when the runtime path has none" do
      path = "/media/movies"
      sync!([runtime_path(path)])

      # Simulate the admin choosing "Every hour" in the UI.
      Repo.get_by!(LibraryPath, path: path)
      |> Ecto.Changeset.change(scan_interval: 3600)
      |> Repo.update!()

      # A restart re-runs the sync with the env var still unset.
      sync!([runtime_path(path)])

      assert Repo.get_by!(LibraryPath, path: path).scan_interval == 3600
    end

    test "writes the interval when the runtime path supplies one" do
      path = "/media/tv"
      sync!([runtime_path(path)])

      sync!([runtime_path(path, %{scan_interval: 21600})])

      assert Repo.get_by!(LibraryPath, path: path).scan_interval == 21600
    end

    test "creates a new path with a nil interval, so new libraries default to manual" do
      path = "/media/new"

      sync!([runtime_path(path)])

      row = Repo.get_by!(LibraryPath, path: path)
      assert row.scan_interval == nil
      assert row.from_env == true
    end
  end
end
