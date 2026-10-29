defmodule Mydia.Indexers.Cardigann.Parity.ReplayTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.Parity.{Capture, Replay, RequestKey, Seam}
  alias Mydia.Indexers.Cardigann.Parity.Capture.Exchange

  defp key(path), do: RequestKey.new("GET", "https://harbor.invalid/#{path}", nil)

  defp exchange(path, body),
    do: %Exchange{request: key(path), status: 200, body: body, headers: []}

  defp capture(exchanges),
    do: %Capture{
      definition: "harbor",
      ref: "test",
      query: %{kind: :generic, term: "x"},
      exchanges: exchanges
    }

  test "repeated keys are served in recorded order, then the last repeats" do
    {:ok, pid} = Replay.start_link(capture([exchange("a", "one"), exchange("a", "two")]))

    assert {:ok, %{body: "one"}} = Replay.fetch(pid, key("a"))
    assert {:ok, %{body: "two"}} = Replay.fetch(pid, key("a"))
    assert {:ok, %{body: "two"}} = Replay.fetch(pid, key("a"))
  end

  test "a miss is recorded and returned in order" do
    {:ok, pid} = Replay.start_link(capture([exchange("a", "one")]))

    assert :miss = Replay.fetch(pid, key("b"))
    assert {:ok, _} = Replay.fetch(pid, key("a"))
    assert :miss = Replay.fetch(pid, key("c"))
    assert Replay.misses(pid) == [key("b"), key("c")]
  end

  test "req_plug answers a recorded exchange, a miss and a transport error" do
    err = %Exchange{request: key("err"), error: :timeout}
    {:ok, pid} = Replay.start_link(capture([exchange("a", "hello"), err]))
    plug = Replay.req_plug(pid)

    assert {:ok, %{status: 200, body: "hello"}} =
             Req.get("https://harbor.invalid/a", plug: plug, retry: false)

    assert {:ok, %{status: 404, body: "parity replay miss"}} =
             Req.get("https://harbor.invalid/nope", plug: plug, retry: false)

    assert {:error, %Req.TransportError{reason: :timeout}} =
             Req.get("https://harbor.invalid/err", plug: plug, retry: false)
  end

  describe "Seam" do
    test "is nil by default and restored after with/2" do
      assert Seam.current() == nil
      assert Seam.with(%{replay: self()}, fn -> Seam.current() end) == %{replay: self()}
      assert Seam.current() == nil
    end

    test "is visible to a Task through $callers" do
      pid = self()

      result =
        Seam.with(%{replay: pid}, fn -> Task.async(fn -> Seam.current() end) |> Task.await() end)

      assert result == %{replay: pid}
    end

    test "a dead caller does not crash lookup" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, _, _, _}

      result =
        Task.async(fn ->
          Process.put(:"$callers", [dead])
          Seam.current()
        end)
        |> Task.await()

      assert result == nil
    end
  end
end
