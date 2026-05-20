defmodule Mydia.Streaming.Torrent.PromotionTest do
  use Mydia.DataCase
  alias Mydia.Streaming.Torrent.{SessionSchema, Promotion}
  alias Mydia.Library.MediaFile
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

    # Create a session record with staging_path set
    {:ok, session} =
      Repo.insert(%SessionSchema{
        user_id: user.id,
        media_item_id: media_item.id,
        magnet: "magnet:?xt=urn:btih:dummy",
        infohash: "dummy_hash",
        release_title: "Test Movie",
        state: :downloading,
        staging_path: staging_file,
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
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    assert {:error, :staging_path_missing} = Promotion.promote(session_no_staging.id)
  end
end
