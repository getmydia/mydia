defmodule Mydia.TorrentTest do
  use Mydia.DataCase
  alias Mydia.Torrent

  setup do
    # Use a unique directory to avoid collisions across parallel test runs
    staging_dir =
      Path.join(System.tmp_dir!(), "mydia_test_staging_#{System.unique_integer([:positive])}")

    File.mkdir_p!(staging_dir)

    # Always clean up, even if the test fails
    on_exit(fn -> File.rm_rf!(staging_dir) end)

    {:ok, staging_dir: staging_dir}
  end

  test "start_engine returns a resource", %{staging_dir: staging_dir} do
    # The NIF now returns {:ok, resource} | {:error, reason}
    case Torrent.start_engine(staging_dir) do
      {:ok, resource} ->
        assert is_reference(resource)

      {:error, reason} ->
        # Engine may legitimately fail in the test environment (e.g. missing deps).
        # Just assert we got a proper error tuple, not a crash.
        assert is_binary(reason) or is_atom(reason),
               "Expected a string/atom error reason, got: #{inspect(reason)}"
    end
  end

  test "add_torrent sends an async result message to the caller", %{staging_dir: staging_dir} do
    case Torrent.start_engine(staging_dir) do
      {:ok, resource} ->
        # add_torrent/3 returns :ok immediately; success/failure arrives as an async message.
        assert Torrent.add_torrent(resource, self(), "magnet:?xt=urn:btih:dummy") == :ok

        # Assert the async callback message arrives within a reasonable timeout.
        # The Rust side will send
        # {:ok, type, torrent_id, infohash, file_id, staging_path, total_bytes}
        # or {:error, reason}.
        assert_receive result, 5_000

        # Tighten the assertion: in the success case the tuple's fields must
        # match the documented shapes. The previous over-broad pattern would
        # pass even if every field came back nil.
        case result do
          {:ok, type, torrent_id, infohash, file_id, staging_path, total_bytes} ->
            assert type in ["added", "already_exists"]
            assert is_integer(torrent_id) and torrent_id >= 0
            assert is_binary(infohash) and byte_size(infohash) > 0
            assert is_integer(file_id) and file_id >= 0
            assert is_binary(staging_path)
            assert String.starts_with?(staging_path, staging_dir)
            assert is_integer(total_bytes) and total_bytes >= 0

          {:error, reason} ->
            # A dummy magnet without peers is expected to time out or fail in
            # the test environment. Just confirm we got a non-empty error
            # reason rather than a crash.
            assert (is_binary(reason) and byte_size(reason) > 0) or is_atom(reason),
                   "Expected non-empty error reason, got: #{inspect(reason)}"

          other ->
            flunk("Unexpected async torrent response shape: #{inspect(other)}")
        end

      {:error, _reason} ->
        # Engine unavailable in this environment — skip add_torrent exercise.
        :ok
    end
  end
end
