defmodule Mydia.Plugins.ConnectTest do
  use Mydia.DataCase, async: false

  alias Mydia.Plugins.Connect
  alias Mydia.Plugins.Error

  # A stub guest keyed by step, so the driver is tested without a wasm build.
  defp stub(responses) do
    fn _slug, %{step: step} = req ->
      case Map.fetch(responses, step) do
        {:ok, fun} when is_function(fun, 1) -> fun.(req)
        {:ok, value} -> value
        :error -> {:error, "unexpected step #{step}"}
      end
    end
  end

  test "start returns a pending session carrying the code" do
    invoke =
      stub(%{
        "start" =>
          {:ok,
           {:pending,
            %{
              message: "Enter this code",
              code: "ABCD",
              verification_url: "https://plex.tv/link",
              interval_ms: 1000,
              state_json: ~s({"pin":"1"})
            }}}
      })

    assert {:ok, session} = Connect.start("plex", invoke: invoke)
    assert session.status == :pending
    assert session.code == "ABCD"
    assert session.interval_ms == 1000
  end

  test "poll echoes the previous state back to the guest" do
    invoke =
      stub(%{
        "start" =>
          {:ok,
           {:pending,
            %{
              message: "m",
              code: "ABCD",
              verification_url: nil,
              interval_ms: 10,
              state_json: ~s({"pin":"1"})
            }}},
        "poll" => fn req ->
          assert req.state_json == ~s({"pin":"1"})
          {:ok, {:done, %{message: "Connected"}}}
        end
      })

    {:ok, session} = Connect.start("plex", invoke: invoke)
    assert {:ok, done} = Connect.poll(session.id, invoke: invoke)
    assert done.status == :done
    assert done.message == "Connected"
  end

  test "a prompt surfaces choices and submit echoes the operator's input" do
    invoke =
      stub(%{
        "start" =>
          {:ok,
           {:prompt,
            %{
              message: "Pick a server",
              fields: [],
              choices: [%{value: "s1", label: "Living room", detail: "10.0.0.5"}],
              state_json: ~s({"token":"t"})
            }}},
        "submit" => fn req ->
          assert req.input_json == ~s({"choice":"s1"})
          assert req.state_json == ~s({"token":"t"})
          {:ok, {:done, %{message: "Added Living room"}}}
        end
      })

    {:ok, session} = Connect.start("plex", invoke: invoke)
    assert session.status == :prompt
    assert [%{value: "s1"}] = session.choices

    assert {:ok, done} = Connect.submit(session.id, %{"choice" => "s1"}, invoke: invoke)
    assert done.status == :done
  end

  test "a session expires and stops accepting turns" do
    invoke =
      stub(%{
        "start" =>
          {:ok,
           {:pending,
            %{message: "m", code: "A", verification_url: nil, interval_ms: 10, state_json: "{}"}}}
      })

    {:ok, session} = Connect.start("plex", invoke: invoke, ttl_ms: 0)

    assert {:error, %Error{type: :not_found}} = Connect.poll(session.id, invoke: invoke)
  end

  test "a guest error ends the session" do
    invoke = stub(%{"start" => {:error, "provider unreachable"}})

    assert {:error, %Error{type: :internal, message: "provider unreachable"}} =
             Connect.start("plex", invoke: invoke)
  end

  test "a finished session is dropped" do
    invoke = stub(%{"start" => {:ok, {:done, %{message: "ok"}}}})

    {:ok, session} = Connect.start("plex", invoke: invoke)
    assert {:error, %Error{type: :not_found}} = Connect.poll(session.id, invoke: invoke)
  end

  test "cancel drops the session" do
    invoke =
      stub(%{
        "start" =>
          {:ok,
           {:pending,
            %{message: "m", code: "A", verification_url: nil, interval_ms: 10, state_json: "{}"}}}
      })

    {:ok, session} = Connect.start("plex", invoke: invoke)
    assert :ok = Connect.cancel(session.id)
    assert {:error, %Error{type: :not_found}} = Connect.poll(session.id, invoke: invoke)
  end
end
