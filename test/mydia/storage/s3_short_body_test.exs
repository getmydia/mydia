defmodule Mydia.Storage.S3ShortBodyTest do
  use ExUnit.Case, async: true

  alias Mydia.Settings.StorageBackend
  alias Mydia.Storage.{Error, Location, S3}

  setup do
    bypass = Bypass.open()

    backend = %StorageBackend{
      name: "m",
      endpoint: "http://localhost:#{bypass.port}",
      region: "us-east-1",
      bucket: "lib",
      access_key_id: "k",
      secret_access_key: "s",
      path_style: true
    }

    %{bypass: bypass, loc: Location.s3(backend, "movies/", "s3://m/movies")}
  end

  defp serve(bypass, body) do
    Bypass.expect(bypass, "GET", "/lib/movies/film.mkv", &Plug.Conn.resp(&1, 206, body))
  end

  test "stream_range with fewer bytes than requested is a provider error", %{
    bypass: bypass,
    loc: loc
  } do
    serve(bypass, "abc")

    assert {:error, %Error{kind: :provider, message: message}} =
             S3.stream_range(loc, "film.mkv", 0, 10, [], fn c, acc -> {:ok, [acc, c]} end)

    assert message =~ "unexpected end of stream"
    refute message =~ "X-Amz"
  end

  test "read_range with fewer bytes than requested is a provider error", %{
    bypass: bypass,
    loc: loc
  } do
    serve(bypass, "abc")
    assert {:error, %Error{kind: :provider}} = S3.read_range(loc, "film.mkv", 0, 10)
  end

  test "a full-length body is still a success", %{bypass: bypass, loc: loc} do
    serve(bypass, "0123456789")
    assert {:ok, "0123456789"} = S3.read_range(loc, "film.mkv", 0, 10)
  end

  test "a caller fold error passes through unchanged", %{bypass: bypass, loc: loc} do
    serve(bypass, "0123456789")

    assert {:error, :closed} =
             S3.stream_range(loc, "film.mkv", 0, 10, nil, fn _c, _acc -> {:error, :closed} end)
  end
end
