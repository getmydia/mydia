defmodule Mydia.P2p.ServerStorageStreamTest do
  use ExUnit.Case, async: false

  @moduletag :s3

  alias Mydia.P2p.HlsRequest
  alias Mydia.P2p.Server
  alias Mydia.S3Helpers
  alias Mydia.Storage.Source

  setup do
    loc = S3Helpers.unique_location(S3Helpers.backend())
    S3Helpers.put_object!(loc, "film.mp4", "0123456789")
    on_exit(fn -> S3Helpers.delete_prefix!(loc) end)
    Process.register(self(), :recording_p2p_nif)
    %{source: Source.new(loc, "film.mp4")}
  end

  defp collect_chunks(acc \\ "") do
    receive do
      {:p2p, :chunk, [_, _, data]} -> collect_chunks(acc <> data)
    after
      0 -> acc
    end
  end

  test "a range request sends a 206 header, the bytes and finishes", %{source: source} do
    Server.stream_storage_file(:res, "s1", source, %HlsRequest{range_start: 2, range_end: 4})

    assert_received {:p2p, :header, [:res, "s1", header]}
    assert header.status == 206
    assert header.content_range == "bytes 2-4/10"
    assert header.content_length == 3
    assert collect_chunks() == "234"
    assert_received {:p2p, :finish, [:res, "s1"]}
  end

  test "a full request sends a 200 header and the whole object", %{source: source} do
    Server.stream_storage_file(:res, "s2", source, %HlsRequest{})

    assert_received {:p2p, :header, [:res, "s2", %{status: 200, content_length: 10}]}
    assert collect_chunks() == "0123456789"
    assert_received {:p2p, :finish, [:res, "s2"]}
  end

  test "a missing object streams nothing", %{source: source} do
    Server.stream_storage_file(:res, "s3", %{source | relative_path: "nope.mp4"}, %HlsRequest{})

    refute_received {:p2p, :chunk, _}
    refute_received {:p2p, :finish, _}
  end
end
