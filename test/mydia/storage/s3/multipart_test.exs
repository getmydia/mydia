defmodule Mydia.Storage.S3.MultipartTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Mydia.Settings.StorageBackend
  alias Mydia.Storage
  alias Mydia.Storage.{Error, Location}

  @mib 1024 * 1024

  setup %{tmp_dir: tmp_dir} do
    bypass = Bypass.open()

    backend = %StorageBackend{
      name: "m",
      endpoint: "http://localhost:#{bypass.port}",
      region: "us-east-1",
      bucket: "lib",
      access_key_id: "AKID",
      secret_access_key: "SECRET",
      path_style: true
    }

    file = Path.join(tmp_dir, "big.mkv")
    File.write!(file, :binary.copy("b", 11 * @mib))

    %{bypass: bypass, location: Location.s3(backend, "movies/", "s3://m/movies"), big: file}
  end

  defp initiate(bypass) do
    Bypass.expect_once(bypass, "POST", "/lib/movies/big.mkv", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      if Map.has_key?(conn.query_params, "uploads") do
        Plug.Conn.resp(
          conn,
          200,
          "<InitiateMultipartUploadResult><UploadId>U1</UploadId></InitiateMultipartUploadResult>"
        )
      else
        Plug.Conn.resp(conn, 200, "<Error><Code>InternalError</Code></Error>")
      end
    end)
  end

  # Holds every part until `n` distinct parts are in flight at once. A
  # sequential loop never gets past 1, so it times out and the part fails.
  # Slots are per part so Req's retry of a 500 cannot inflate the count.
  defp await_in_flight(counter, part, n, deadline_ms \\ 2_000) do
    :atomics.put(counter, String.to_integer(part), 1)
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    spin(counter, n, deadline)
  end

  defp in_flight(counter),
    do: Enum.sum(for i <- 1..:atomics.info(counter).size, do: :atomics.get(counter, i))

  defp spin(counter, n, deadline) do
    cond do
      in_flight(counter) >= n ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        :timeout

      true ->
        Process.sleep(10)
        spin(counter, n, deadline)
    end
  end

  # Answers both POSTs on the key: the initiate (?uploads) and the Complete.
  defp complete(bypass, test_pid) do
    Bypass.expect(bypass, "POST", "/lib/movies/big.mkv", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      if Map.has_key?(conn.query_params, "uploads") do
        Plug.Conn.resp(
          conn,
          200,
          "<InitiateMultipartUploadResult><UploadId>U1</UploadId></InitiateMultipartUploadResult>"
        )
      else
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:complete_body, body})
        Plug.Conn.resp(conn, 200, "<CompleteMultipartUploadResult/>")
      end
    end)
  end

  defp part_numbers(body),
    do: ~r{<PartNumber>(\d+)</PartNumber>} |> Regex.scan(body) |> Enum.map(&List.last/1)

  test "upload parts are in flight at the same time", %{bypass: bypass, location: loc, big: big} do
    test_pid = self()
    counter = :atomics.new(3, [])
    complete(bypass, test_pid)

    Bypass.expect(bypass, "PUT", "/lib/movies/big.mkv", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      {:ok, _body, conn} = Plug.Conn.read_body(conn, length: 20 * @mib)
      n = conn.query_params["partNumber"]

      case await_in_flight(counter, n, 3) do
        :ok -> conn |> Plug.Conn.put_resp_header("etag", "\"p#{n}\"") |> Plug.Conn.resp(200, "")
        :timeout -> Plug.Conn.resp(conn, 500, "")
      end
    end)

    {:ok, dest} = Storage.source(loc, "big.mkv")
    assert :ok = Storage.put_file(dest, big, part_size: 5 * @mib)
    assert_received {:complete_body, body}
    assert part_numbers(body) == ["1", "2", "3"]
  end

  test "Complete lists parts in order when they finish out of order", %{
    bypass: bypass,
    location: loc,
    big: big
  } do
    test_pid = self()
    complete(bypass, test_pid)

    Bypass.expect(bypass, "PUT", "/lib/movies/big.mkv", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      {:ok, _body, conn} = Plug.Conn.read_body(conn, length: 20 * @mib)
      n = conn.query_params["partNumber"]
      if n == "1", do: Process.sleep(300)
      conn |> Plug.Conn.put_resp_header("etag", "\"p#{n}\"") |> Plug.Conn.resp(200, "")
    end)

    {:ok, dest} = Storage.source(loc, "big.mkv")
    assert :ok = Storage.put_file(dest, big, part_size: 5 * @mib)
    assert_received {:complete_body, body}
    assert part_numbers(body) == ["1", "2", "3"]
    assert body =~ ~r{<PartNumber>1</PartNumber><ETag>&quot;p1&quot;</ETag>}
  end

  test "copy parts are in flight at the same time", %{bypass: bypass, location: loc} do
    test_pid = self()
    counter = :atomics.new(3, [])
    complete(bypass, test_pid)

    # config/test.exs: copy_threshold 10 MiB, copy_part_size 5 MiB, so 3 parts.
    Bypass.expect(bypass, "HEAD", "/lib/movies/src.mkv", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-length", Integer.to_string(11 * @mib))
      |> Plug.Conn.send_resp(200, :binary.copy("x", 11 * @mib))
    end)

    Bypass.expect(bypass, "PUT", "/lib/movies/big.mkv", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      n = conn.query_params["partNumber"]

      case await_in_flight(counter, n, 3) do
        :ok ->
          Plug.Conn.resp(conn, 200, "<CopyPartResult><ETag>\"c#{n}\"</ETag></CopyPartResult>")

        :timeout ->
          Plug.Conn.resp(conn, 500, "")
      end
    end)

    {:ok, from} = Storage.source(loc, "src.mkv")
    {:ok, to} = Storage.source(loc, "big.mkv")
    assert :ok = Storage.copy(from, to)
    assert_received {:complete_body, body}
    assert part_numbers(body) == ["1", "2", "3"]
  end

  test "a failed part aborts the upload and completes nothing", %{
    bypass: bypass,
    location: loc,
    big: big
  } do
    initiate(bypass)
    test_pid = self()

    Bypass.expect(bypass, "PUT", "/lib/movies/big.mkv", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      {:ok, _body, conn} = Plug.Conn.read_body(conn, length: 20 * @mib)

      case conn.query_params["partNumber"] do
        "1" -> conn |> Plug.Conn.put_resp_header("etag", "\"p1\"") |> Plug.Conn.resp(200, "")
        _ -> Plug.Conn.resp(conn, 403, "")
      end
    end)

    Bypass.expect_once(bypass, "DELETE", "/lib/movies/big.mkv", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:aborted, conn.query_params["uploadId"]})
      Plug.Conn.resp(conn, 204, "")
    end)

    {:ok, dest} = Storage.source(loc, "big.mkv")
    assert {:error, %Error{kind: :forbidden}} = Storage.put_file(dest, big, part_size: 5 * @mib)
    assert_received {:aborted, "U1"}
  end

  test "a Complete answered with an Error body aborts", %{
    bypass: bypass,
    location: loc,
    big: big
  } do
    test_pid = self()

    Bypass.expect(bypass, "POST", "/lib/movies/big.mkv", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      if Map.has_key?(conn.query_params, "uploads") do
        Plug.Conn.resp(
          conn,
          200,
          "<InitiateMultipartUploadResult><UploadId>U1</UploadId></InitiateMultipartUploadResult>"
        )
      else
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:complete_body, body})
        Plug.Conn.resp(conn, 200, "<Error><Code>InternalError</Code></Error>")
      end
    end)

    Bypass.expect(bypass, "PUT", "/lib/movies/big.mkv", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      {:ok, _body, conn} = Plug.Conn.read_body(conn, length: 20 * @mib)
      n = conn.query_params["partNumber"]
      conn |> Plug.Conn.put_resp_header("etag", "\"p#{n}\"") |> Plug.Conn.resp(200, "")
    end)

    Bypass.expect_once(bypass, "DELETE", "/lib/movies/big.mkv", fn conn ->
      send(test_pid, :aborted)
      Plug.Conn.resp(conn, 204, "")
    end)

    {:ok, dest} = Storage.source(loc, "big.mkv")
    assert {:error, %Error{kind: :provider}} = Storage.put_file(dest, big, part_size: 5 * @mib)
    assert_received :aborted
    assert_received {:complete_body, body}
    assert body =~ "<PartNumber>3</PartNumber>"
  end
end
