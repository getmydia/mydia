defmodule Mydia.Streaming.Torrent.PromotionTest do
  use Mydia.DataCase
  alias Mydia.Streaming.Torrent.{SessionSchema, Promotion}
  alias Mydia.Repo

  setup do
    user = Mydia.AccountsFixtures.user_fixture()

    # library_path_fixture already generates a unique tmp path internally
    library_path =
      Mydia.SettingsFixtures.library_path_fixture(%{type: "movies"})

    media_item = Mydia.MediaFixtures.media_item_fixture()

    # Use unique staging directories to avoid cross-run collisions
    staging_dir =
      Path.join(
        System.tmp_dir!(),
        "mydia_test_staging_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(staging_dir)

    staging_file = Path.join(staging_dir, "movie.mp4")
    File.write!(staging_file, "dummy content")

    # Create a session record with staging_path set.
    # download_progress: 1.0 is required because Promotion.promote/1 now
    # refuses to promote until the engine has finished downloading.
    {:ok, session} =
      Repo.insert(%SessionSchema{
        user_id: user.id,
        media_item_id: media_item.id,
        magnet: "magnet:?xt=urn:btih:dummy",
        infohash: "dummy_hash",
        release_title: "Test Movie",
        state: :downloading,
        staging_path: staging_file,
        download_progress: 1.0,
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    on_exit(fn ->
      File.rm_rf!(staging_dir)
      # Also clean up destination folder in library_path
      File.rm_rf!(library_path.path)
    end)

    {:ok,
     %{
       session: session,
       staging_file: staging_file,
       library_path: library_path,
       media_item: media_item
     }}
  end

  test "promote/1 moves the staged file into the library and creates a MediaFile record", %{
    session: session,
    staging_file: staging_file,
    library_path: library_path,
    media_item: media_item
  } do
    # Ensure the source file exists before promotion
    assert File.exists?(staging_file)

    # Call the real promotion entry point
    assert {:ok, media_file} = Promotion.promote(session.id)

    # The returned MediaFile should be associated with the right media item and library
    assert media_file.media_item_id == media_item.id
    assert media_file.library_path_id == library_path.id

    # The destination file must exist under library_path
    dest_path = Path.join(library_path.path, media_file.relative_path)
    assert File.exists?(dest_path), "Expected promoted file at #{dest_path}"

    # The staging file should have been moved (no longer present at original location)
    refute File.exists?(staging_file), "Expected staging file to be gone after promotion"

    # The session state should be updated to :completed
    updated_session = Repo.get!(SessionSchema, session.id)
    assert updated_session.state == :completed
  end

  test "promote/1 returns {:error, :not_found} for an unknown session ID" do
    assert {:error, :not_found} = Promotion.promote(Ecto.UUID.generate())
  end

  test "promote/1 returns {:error, :staging_path_missing} when staging_path is nil" do
    user = Mydia.AccountsFixtures.user_fixture()
    media_item = Mydia.MediaFixtures.media_item_fixture()

    {:ok, session_no_staging} =
      Repo.insert(%SessionSchema{
        user_id: user.id,
        media_item_id: media_item.id,
        magnet: "magnet:?xt=urn:btih:dummynostagingpath",
        infohash: "dummy_hash_no_staging",
        release_title: "Test No Staging",
        state: :downloading,
        staging_path: nil,
        download_progress: 1.0,
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    assert {:error, :staging_path_missing} = Promotion.promote(session_no_staging.id)
  end

  test "promote/1 returns :download_incomplete when download_progress < 1.0", %{
    session: session
  } do
    # Force a half-finished download
    {:ok, _} =
      Repo.update(SessionSchema.changeset(session, %{download_progress: 0.5}))

    assert {:ok, :download_incomplete} = Promotion.promote(session.id)

    # Session must remain in its prior (non-terminal) state
    assert Repo.get!(SessionSchema, session.id).state == :downloading
  end

  test "promote/1 refuses to re-promote a session that already reached :completed", %{
    session: session
  } do
    {:ok, _} =
      Repo.update(SessionSchema.changeset(session, %{state: :completed}))

    assert {:error, :not_promotable} = Promotion.promote(session.id)
  end

  describe "DB-failure rollback" do
    test "rolls the staging file back when the MediaFile insert fails", %{
      session: session,
      staging_file: staging_file
    } do
      # Force the Library.create_media_file insert to fail by setting
      # total_bytes to 0 — MediaFile.changeset/2 validates `:size > 0` and
      # rejects the insert with a changeset error. This exercises
      # `create_media_file_with_compensation`'s rollback path: the file
      # moved to dest must be moved back to staging, and no MediaFile row
      # may be left behind.
      {:ok, _} =
        Repo.update(SessionSchema.changeset(session, %{total_bytes: 0}))

      original_count = Repo.aggregate(Mydia.Library.MediaFile, :count, :id)

      assert {:error, _reason} = Promotion.promote(session.id)

      # The staging file should be back at its original location after the
      # rollback. (move_file moved it via rename within the same tmp dir.)
      assert File.exists?(staging_file),
             "Expected staging file to be rolled back to #{staging_file}"

      # No new MediaFile rows should exist.
      assert Repo.aggregate(Mydia.Library.MediaFile, :count, :id) == original_count
    end
  end

  describe "EXDEV cross-device move" do
    defmodule FakeFile do
      @moduledoc false
      # Simulates a filesystem boundary where rename returns :exdev but
      # cp/rm succeed against the real underlying file. Tests the fallback
      # path in `move_file/3` without needing two real mount points.
      def rename(_src, _dest), do: {:error, :exdev}
      defdelegate cp(src, dest), to: File
      defdelegate rm(path), to: File
    end

    test "falls back to copy + rm when File.rename returns :exdev", %{staging_file: src} do
      dest_dir =
        Path.join(System.tmp_dir!(), "mydia_exdev_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dest_dir)
      dest = Path.join(dest_dir, "moved.mp4")

      on_exit(fn -> File.rm_rf!(dest_dir) end)

      assert {:ok, :copied} =
               Mydia.Streaming.Torrent.Promotion.move_file(src, dest, file_module: FakeFile)

      assert File.exists?(dest), "Expected destination file at #{dest}"
      refute File.exists?(src), "Expected source file removed after copy"
    end
  end
end
