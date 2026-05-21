defmodule MydiaWeb.Plugs.ParityCaptureTest do
  use MydiaWeb.ConnCase, async: false

  alias MydiaWeb.Plugs.ParityCapture

  @env_var "MYDIA_PARITY_CAPTURE"

  setup do
    prior = System.get_env(@env_var)

    on_exit(fn ->
      case prior do
        nil -> System.delete_env(@env_var)
        value -> System.put_env(@env_var, value)
      end
    end)

    :ok
  end

  describe "call/2 when MYDIA_PARITY_CAPTURE is unset" do
    test "is a no-op", %{conn: conn} do
      System.delete_env(@env_var)

      conn =
        conn
        |> Map.put(:method, "POST")
        |> Map.put(:request_path, "/api/graphql")
        |> Plug.Conn.put_req_header("content-type", "application/json")

      out = ParityCapture.call(conn, [])

      # Without the env var, no before_send is registered and the conn
      # is returned untouched.
      assert before_send_callbacks(out) == []
    end
  end

  describe "call/2 with MYDIA_PARITY_CAPTURE set" do
    setup do
      path =
        Path.join(System.tmp_dir!(), "parity-capture-#{System.unique_integer([:positive])}.jsonl")

      System.put_env(@env_var, path)

      on_exit(fn -> File.rm(path) end)

      %{path: path}
    end

    test "appends a JSONL record on a POST to /api/graphql", %{conn: conn, path: path} do
      conn =
        conn
        |> Map.put(:method, "POST")
        |> Map.put(:request_path, "/api/graphql")
        |> Map.put(:body_params, %{
          "query" => "query Movies { movies { id } }",
          "operationName" => "Movies",
          "variables" => %{"first" => 20}
        })

      conn
      |> ParityCapture.call([])
      |> Plug.Conn.put_status(200)
      |> Plug.Conn.resp(200, ~s({"data":{"movies":[]}}))
      |> run_before_send()

      assert File.exists?(path)
      [line] = path |> File.read!() |> String.trim() |> String.split("\n")
      record = Jason.decode!(line)

      assert record["query"] == "query Movies { movies { id } }"
      assert record["operation"] == "Movies"
      assert record["variables"] == %{"first" => 20}
      assert record["status"] == 200
      assert record["response"] == %{"data" => %{"movies" => []}}
      assert is_integer(record["elapsed_ms"])
      assert record["elapsed_ms"] >= 0
      assert is_binary(record["ts"])
    end

    test "ignores GETs", %{conn: conn, path: path} do
      conn =
        conn
        |> Map.put(:method, "GET")
        |> Map.put(:request_path, "/api/graphql")

      out = ParityCapture.call(conn, [])
      assert before_send_callbacks(out) == []

      refute File.exists?(path)
    end

    test "ignores non-graphql paths", %{conn: conn, path: path} do
      conn =
        conn
        |> Map.put(:method, "POST")
        |> Map.put(:request_path, "/api/v1/stream/file/123")

      out = ParityCapture.call(conn, [])
      assert before_send_callbacks(out) == []

      refute File.exists?(path)
    end

    test "captures multiple requests as separate JSONL lines", %{conn: base_conn, path: path} do
      for op <- ["FirstOp", "SecondOp"] do
        conn =
          base_conn
          |> Map.put(:method, "POST")
          |> Map.put(:request_path, "/api/graphql")
          |> Map.put(:body_params, %{
            "query" => "query #{op} { __typename }",
            "operationName" => op,
            "variables" => %{}
          })
          |> ParityCapture.call([])
          |> Plug.Conn.put_status(200)
          |> Plug.Conn.resp(200, ~s({"data":{"__typename":"Query"}}))
          |> run_before_send()

        _ = conn
      end

      records =
        path
        |> File.read!()
        |> String.trim()
        |> String.split("\n")
        |> Enum.map(&Jason.decode!/1)

      assert length(records) == 2
      assert Enum.map(records, & &1["operation"]) == ["FirstOp", "SecondOp"]
    end

    test "swallows write errors without raising", %{conn: conn} do
      bad_path = "/nonexistent-directory/parity.jsonl"
      System.put_env(@env_var, bad_path)

      conn =
        conn
        |> Map.put(:method, "POST")
        |> Map.put(:request_path, "/api/graphql")
        |> Map.put(:body_params, %{
          "query" => "{ __typename }",
          "operationName" => nil,
          "variables" => nil
        })

      # The before_send callback must not raise even when the file
      # write fails — the request lifecycle stays clean.
      conn =
        conn
        |> ParityCapture.call([])
        |> Plug.Conn.put_status(200)
        |> Plug.Conn.resp(200, ~s({"data":{"__typename":"Query"}}))

      assert run_before_send(conn).status == 200
    end

    test "handles non-JSON response body without crashing", %{conn: conn, path: path} do
      conn =
        conn
        |> Map.put(:method, "POST")
        |> Map.put(:request_path, "/api/graphql")
        |> Map.put(:body_params, %{
          "query" => "{ __typename }",
          "operationName" => nil,
          "variables" => nil
        })
        |> ParityCapture.call([])
        |> Plug.Conn.put_status(500)
        |> Plug.Conn.resp(500, "Internal Server Error")
        |> run_before_send()

      _ = conn

      [line] = path |> File.read!() |> String.trim() |> String.split("\n")
      record = Jason.decode!(line)
      assert record["status"] == 500
      assert record["response"] == %{"_unparseable_body" => "Internal Server Error"}
    end
  end

  # Manually fire the before_send callbacks that Plug.Conn would
  # otherwise fire as part of `send_resp/1`. We don't actually
  # transmit the response in tests.
  defp run_before_send(conn) do
    Enum.reduce(before_send_callbacks(conn), conn, fn cb, acc -> cb.(acc) end)
  end

  defp before_send_callbacks(conn) do
    # `register_before_send/2` stores callbacks under
    # `conn.private[:before_send]` (prepended, so reverse to fire in
    # registration order).
    conn.private
    |> Map.get(:before_send, [])
    |> Enum.reverse()
  end
end
