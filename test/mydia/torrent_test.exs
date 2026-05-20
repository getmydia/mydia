defmodule Mydia.TorrentTest do
  use Mydia.DataCase
  alias Mydia.Torrent

  test "start_engine and add_torrent" do
    staging_dir = "/tmp/mydia_test_staging"
    File.mkdir_p!(staging_dir)

    resource = Torrent.start_engine(staging_dir)
    assert is_reference(resource)

    # Test add_torrent with a dummy magnet (will probably fail in Rust, but we check NIF call)
    # Actually, let's just check if it returns :ok
    assert Torrent.add_torrent(resource, self(), "magnet:?xt=urn:btih:dummy") == :ok

    # Clean up
    File.rm_rf!(staging_dir)
  end
end
