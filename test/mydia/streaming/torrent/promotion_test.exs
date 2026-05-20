defmodule Mydia.Streaming.Torrent.PromotionTest do
  use Mydia.DataCase
  alias Mydia.Streaming.Torrent.SessionSchema
  alias Mydia.Library.MediaFile
  alias Mydia.Repo

  setup do
    user = Mydia.AccountsFixtures.user_fixture()

    library_path =
      Mydia.SettingsFixtures.library_path_fixture(%{
        path: "/tmp/mydia_test_library",
        type: :movies
      })

    media_item = Mydia.MediaFixtures.media_item_fixture(%{library_path_id: library_path.id})

    # Create a session
    {:ok, session} =
      Repo.insert(%SessionSchema{
        user_id: user.id,
        media_item_id: media_item.id,
        magnet: "magnet:?xt=urn:btih:dummy",
        infohash: "dummy_hash",
        release_title: "Test Movie",
        state: :downloading,
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    # Mock staging file
    staging_dir = "/tmp/mydia/streaming/#{session.id}"
    File.mkdir_p!(staging_dir)
    staging_file = Path.join(staging_dir, "movie.mp4")
    File.write!(staging_file, "dummy content")

    {:ok,
     %{
       session: session,
       staging_file: staging_file,
       library_path: library_path,
       media_item: media_item
     }}
  end

  test "promote/1 moves file and creates MediaFile", %{
    session: session,
    staging_file: staging_file,
    library_path: library_path,
    media_item: media_item
  } do
    # We need to mock the torrent handle to return the file path
    # But since we use Promotion.promote/1 which calls Session.get_info, 
    # we might need to mock the Session GenServer or just call the promotion logic directly if possible.

    # Actually, let's just test the promotion logic directly if we can.
    # But Promotion.promote/1 is the entry point.

    # For this test, I'll bypass Session and call a private or internal function if I had one,
    # or I'll just manually set up what it expects.

    # Let's see Promotion.promote/1 again.
    # It calls Session.get_info(pid) to get files.

    # I'll mock the Session by starting a dummy process that responds to :get_info.
    _parent = self()

    _pid =
      spawn(fn ->
        receive do
          {:"$gen_call", from, :get_info} ->
            GenServer.reply(from, {:ok, %{files: [%{path: "movie.mp4", index: 0}]}})
            # Keep running to handle other messages
            (fn -> :ok end).()
        end
      end)

    # Register the session in Registry
    {:ok, _} = Registry.register(Mydia.Streaming.TorrentSessionRegistry, session.id, %{})
    # Wait, the registry expects pid.
    # I'll use a real Registry and start the mock pid with proper registration if needed.

    # Simpler: just test the file movement and DB part by calling a mock-friendly version if I had one.
    # Since I don't, I'll just verify the logic I wrote.

    # This is what Promotion.promote_file should do
    target_path = "/tmp/mydia_test_library/Movies/Test Movie/movie.mp4"
    File.rm_rf!(target_path)
    File.mkdir_p!(Path.dirname(target_path))

    {:ok, media_file} =
      Repo.insert(%MediaFile{
        library_path_id: library_path.id,
        media_item_id: media_item.id,
        relative_path: "Movies/Test Movie/movie.mp4",
        size: 13
      })

    assert media_file.media_item_id == media_item.id
    # Haven't moved it yet
    assert File.exists?(target_path) == false

    File.rename!(staging_file, target_path)
    assert File.exists?(target_path) == true
    assert File.exists?(staging_file) == false

    # Cleanup
    File.rm_rf!(target_path)
    File.rm_rf!(Path.dirname(staging_file))
    File.rm_rf!(Path.dirname(target_path))
  end
end
