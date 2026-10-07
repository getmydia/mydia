defmodule Mydia.Storage.S3StatTest do
  # Bypass (Cowboy) rewrites content-length from the body, so a malformed
  # header needs a raw socket server.
  use ExUnit.Case, async: true

  alias Mydia.Settings.StorageBackend
  alias Mydia.Storage.{Error, Location, S3}

  defp serve_head(content_length) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)

    pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\ncontent-length: #{content_length}\r\n" <>
            "last-modified: Wed, 01 Oct 2031 10:00:00 GMT\r\nconnection: close\r\n\r\n"
        )

        :gen_tcp.close(socket)
      end)

    on_exit(fn ->
      Process.unlink(pid)
      Process.exit(pid, :kill)
      :gen_tcp.close(listener)
    end)

    backend = %StorageBackend{
      name: "m",
      endpoint: "http://localhost:#{port}",
      region: "us-east-1",
      bucket: "lib",
      access_key_id: "k",
      secret_access_key: "s",
      path_style: true
    }

    Location.s3(backend, "movies/", "s3://m/movies")
  end

  test "a numeric content-length is the size" do
    assert {:ok, %{size: 1234}} = S3.stat(serve_head("1234"), "film.mkv")
  end

  # Mint already rejects a malformed content-length over HTTP/1, so this
  # guards the observable contract (an error, never a raise) rather than the
  # Integer.parse branch itself.
  test "a non-numeric content-length is an error, not a crash" do
    assert {:error, %Error{}} = S3.stat(serve_head("abc"), "film.mkv")
  end
end
