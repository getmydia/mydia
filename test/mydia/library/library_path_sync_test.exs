defmodule Mydia.Library.LibraryPathSyncTest do
  use Mydia.DataCase, async: false

  alias Mydia.Library.LibraryPathSync
  alias Mydia.Repo
  alias Mydia.Settings
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

      # Simulate a DB-set value that config-supplied sync must override, not
      # just leave alone. Syncing nil then a real value would still pass
      # against an implementation that only writes when the DB value is empty.
      Repo.get_by!(LibraryPath, path: path)
      |> Ecto.Changeset.change(scan_interval: 3600)
      |> Repo.update!()

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

  describe "Settings.create_library_path/1 without the SQLite scan_interval default" do
    test "a path created with no explicit interval reloads as nil, not the leftover SQLite default" do
      path = "/media/admin-created"

      assert {:ok, _library_path} = Settings.create_library_path(%{path: path, type: :movies})

      # The returned struct is not proof by itself: before the DEFAULT 3600 was
      # dropped from the library_paths table, Ecto's insert omitted the
      # scan_interval column entirely (its cast value, nil, equaled the fresh
      # struct's own value), so the leftover SQLite column default silently
      # won. The in-memory struct still reported nil even while the row said
      # 3600, so only a fresh reload from the database proves the fix.
      assert Repo.get_by!(LibraryPath, path: path).scan_interval == nil
    end
  end

  describe "end-to-end: real Mydia.Config.Schema composition, no env mutation" do
    # Settings.get_runtime_library_paths/0 (which sync_from_runtime_config/0
    # reads from) is driven by Application.get_env(:mydia, :runtime_config, ...),
    # not by hand-built LibraryPath structs. Swapping that application env key
    # for the duration of one test reaches the real production composition
    # (Mydia.Config.Schema -> its embedded LibraryPath -> RuntimeConfig mapping)
    # without touching OS env vars, so it does not violate the
    # no-global-env-mutation convention.
    setup do
      previous = Application.get_env(:mydia, :runtime_config)
      on_exit(fn -> Application.put_env(:mydia, :runtime_config, previous) end)
      :ok
    end

    test "a config-sourced library path with no scan_interval persists as nil, not the embedded schema default" do
      path = "/media/config-sourced"

      changeset =
        Mydia.Config.Schema.changeset(Mydia.Config.Schema.defaults(), %{
          library_paths: [%{path: path, type: "movies"}]
        })

      {:ok, config} = Ecto.Changeset.apply_action(changeset, :insert)
      Application.put_env(:mydia, :runtime_config, config)

      assert {:ok, _stats} = LibraryPathSync.sync_from_runtime_config()

      assert Repo.get_by!(LibraryPath, path: path).scan_interval == nil
    end
  end
end
