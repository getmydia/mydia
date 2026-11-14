defmodule Mydia.Downloads.BuiltIn.LimitsRuntimeTest do
  # Not async: the runtime entry is a global persistent_term.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Mydia.Downloads.BuiltIn
  alias Mydia.Downloads.BuiltIn.{Config, Limits, Runtime, Status}
  alias Mydia.Downloads.Client.Rqbit

  setup do
    on_exit(&BuiltIn.clear_runtime/0)
    :ok
  end

  test "a Limits started with a stale config pushes the live limits from the runtime entry" do
    bypass = Bypass.open()
    test_pid = self()

    Bypass.stub(bypass, "POST", "/torrents/limits", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:limits_body, Jason.decode!(body)})
      Plug.Conn.resp(conn, 200, "{}")
    end)

    client = %{
      type: :rqbit,
      host: "localhost",
      port: bypass.port,
      username: nil,
      password: nil,
      use_ssl: false,
      options: %{}
    }

    BuiltIn.put_runtime(%Runtime{
      api_port: bypass.port,
      credentials: {"u", "p"},
      config: %Config{download_limit: 200}
    })

    uniq = System.unique_integer([:positive])
    status = :"limits_rt_status_#{uniq}"
    topic = "built_in_status:limits_rt:#{uniq}"
    start_supervised!({Status, name: status, topic: topic})

    start_supervised!(
      {Limits,
       name: :"limits_rt_#{uniq}",
       config: %Config{download_limit: 100},
       status: status,
       topic: topic,
       resolve: fn -> {:ok, Rqbit, client} end}
    )

    Status.put(status, :engine, :running)

    assert_receive {:limits_body, %{"download_bps" => 204_800}}
  end
end
