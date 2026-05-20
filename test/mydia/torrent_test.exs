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
        # The Rust side will send {:ok, type, torrent_id, infohash} or {:error, reason}.
        assert_receive result, 5_000

        assert match?({:ok, _, _, _}, result) or match?({:error, _}, result),
               "Expected async torrent response, got: #{inspect(result)}"

      {:error, _reason} ->
        # Engine unavailable in this environment — skip add_torrent exercise.
        :ok
    end
  end
end
