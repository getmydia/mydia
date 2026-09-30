defmodule Mydia.Plugins.ContractV15Test do
  # async: false: starts real pools under the app-wide PoolRegistry.
  use Mydia.DataCase, async: false

  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Host
  alias Mydia.Plugins.HostFunctions
  alias Mydia.Plugins.Logs

  @fixtures Path.join([__DIR__, "..", "..", "support", "fixtures", "plugins"])

  defp start(slug, file) do
    bytes = File.read!(Path.join(@fixtures, file))
    {:ok, _} = Host.start_plugin(slug, bytes, imports: HostFunctions.imports_for(slug))
    on_exit(fn -> Host.stop_plugin(slug) end)
  end

  defp setup_payload(step, input \\ %{}, state \\ %{}) do
    %{
      "step" => step,
      "input_json" => Jason.encode!(input),
      "state_json" => Jason.encode!(state),
      "config" => %{"instance_id" => "inst-1"}
    }
  end

  test "detects a 1.5 guest, a 1.4 page guest and an older guest" do
    start("v15-detect", "host_v15_fixture.wasm")
    start("v14-detect", "page_fixture.wasm")
    start("v13-detect", "host_fns_fixture.wasm")

    assert Host.contract_version("v15-detect") == :v15
    assert Host.contract_version("v14-detect") == :v14
    assert Host.contract_version("v13-detect") in [:v11, :v12, :v13]
  end

  test "setup and check-health are unsupported on a 1.4 page guest" do
    start("v14-unsupported", "page_fixture.wasm")

    assert {:error, %Error{type: :unsupported}} =
             Host.call("v14-unsupported", "setup", setup_payload("start"), handler: :setup)

    assert {:error, %Error{type: :unsupported}} =
             Host.call("v14-unsupported", "check-health", %{}, handler: :check_health)
  end

  test "a 1.5 guest still handles events and schedule ticks" do
    start("v14-events", "host_v15_fixture.wasm")

    assert {:ok, %{"config" => %{"instance_id" => "inst-1"}}} =
             Host.call("v14-events", "handle", %{
               "event" => "config",
               "config" => %{"instance_id" => "inst-1"}
             })

    assert {:ok, %{"scheduled" => true, "config" => %{"instance_id" => "inst-1"}}} =
             Host.call(
               "v14-events",
               "handle",
               %{"slug" => "v14-events", "config" => %{"instance_id" => "inst-1"}},
               handler: :on_schedule
             )
  end

  test "setup walks auth, poll, choice with endpoints and credentials" do
    start("v14-setup", "host_v15_fixture.wasm")
    call = fn p -> Host.call("v14-setup", "setup", p, handler: :setup) end

    assert {:ok, auth} = call.(setup_payload("start"))
    assert auth.step == "auth"
    assert auth.credentials == []
    assert auth.error == nil

    assert auth.body ==
             {:external_auth,
              %{url: "https://auth.example.invalid/pin", poll_after_seconds: 1, message: nil}}

    assert Jason.decode!(auth.next_state_json) == %{"polls" => 0}

    assert {:ok, again} = call.(setup_payload("poll", %{}, %{"polls" => 0}))
    assert {:external_auth, _} = again.body
    assert Jason.decode!(again.next_state_json) == %{"polls" => 1}

    assert {:ok, choice} = call.(setup_payload("poll", %{}, %{"polls" => 1}))
    assert choice.step == "pick"
    assert choice.credentials == [%{role: :owner, token: "owner-token"}]
    assert Jason.decode!(choice.next_state_json) == %{"stage" => "picked"}

    assert {:choice, %{title: "Pick a server", options: [a, b]}} = choice.body

    assert a == %{
             id: "server-a",
             label: "Server A",
             detail: "http://127.0.0.1:32400",
             badge: "local",
             endpoints: [%{scheme: "http", host: "127.0.0.1", port: 32400}],
             credentials: [%{role: :endpoint, token: "endpoint-token-a"}]
           }

    assert b.id == "server-b"
    assert b.detail == nil
    assert b.badge == nil
    assert b.endpoints == [%{scheme: "https", host: "b.example.invalid", port: 443}]
    assert b.credentials == []
  end

  test "setup decodes mapping, form and done screens and guest errors" do
    start("v14-screens", "host_v15_fixture.wasm")
    call = fn p -> Host.call("v14-screens", "setup", p, handler: :setup) end

    payload =
      setup_payload("pick", %{"option_id" => "server-a"})
      |> put_in(["config", "suggest_user_id"], "u-1")

    assert {:ok, %{body: {:mapping, mapping}, step: "map", next_state_json: state}} =
             call.(payload)

    assert Jason.decode!(state) == %{"server" => "server-a"}

    assert mapping.accounts == [
             %{id: "acct-1", name: "Remote Alice", admin: true},
             %{id: "acct-2", name: "Remote Bob", admin: false}
           ]

    assert mapping.suggestions == [%{remote_account_id: "acct-1", user_id: "u-1"}]

    assert {:ok, %{body: {:mapping, %{suggestions: []}}}} =
             call.(setup_payload("pick", %{"option_id" => "server-b"}))

    assert {:ok, %{body: {:done, "Linked 2 accounts"}, step: "done"}} =
             call.(setup_payload("map", %{"links" => [%{}, %{}]}))

    assert {:ok, %{step: "manual", body: {:form, form}, error: nil}} =
             call.(setup_payload("manual-start"))

    assert form.title == "Enter server details"

    assert form.fields == [
             %{
               key: "url",
               label: "Server URL",
               field_type: "url",
               required: true,
               options: [],
               default_value: nil
             },
             %{
               key: "token",
               label: "Token",
               field_type: "secret",
               required: false,
               options: [],
               default_value: nil
             }
           ]

    assert {:ok, %{body: {:form, _}, error: "url is empty"}} =
             call.(setup_payload("manual", %{"url" => "", "token" => ""}))

    assert {:ok,
            %{
              body: {:done, "Manual http://10.0.0.5:32400"},
              credentials: [%{role: :owner, token: "t-1"}]
            }} =
             call.(setup_payload("manual", %{"url" => "http://10.0.0.5:32400", "token" => "t-1"}))

    assert {:ok, %{credentials: []}} =
             call.(setup_payload("manual", %{"url" => "http://10.0.0.5:32400", "token" => ""}))

    assert {:error, %Error{type: :guest_error, message: "fixture failure"}} =
             call.(setup_payload("fail"))

    assert {:error, %Error{type: :guest_error, message: "unknown step nope"}} =
             call.(setup_payload("nope"))
  end

  test "check-health decodes the health record" do
    start("v14-health", "host_v15_fixture.wasm")

    assert {:ok, %{status: :degraded, message: "fixture degraded", action: :reconnect}} =
             Host.call("v14-health", "check-health", %{}, handler: :check_health)
  end

  describe "end markers for typed results" do
    defp end_marker(slug) do
      slug
      |> Logs.recent()
      |> Enum.find(&(&1.source == :host and &1.metadata["phase"] == "end"))
    end

    defp logged_text(slug) do
      slug
      |> Logs.recent()
      |> Enum.map_join("\n", &(&1.message <> " " <> Jason.encode!(&1.metadata)))
    end

    test "a setup marker names the step and body, never the state or error text" do
      start("v14-log-state", "host_v15_fixture.wasm")

      # The fixture echoes option_id into next-state-json, standing in for a
      # PIN or token a real plugin carries between steps.
      assert {:ok, %{next_state_json: state}} =
               Host.call(
                 "v14-log-state",
                 "setup",
                 setup_payload("pick", %{"option_id" => "pin-secret-4821"}),
                 handler: :setup
               )

      assert state =~ "pin-secret-4821"

      assert end_marker("v14-log-state").metadata["detail"] == "step=map body=mapping"
      refute logged_text("v14-log-state") =~ "pin-secret-4821"

      start("v14-log-error", "host_v15_fixture.wasm")

      assert {:ok, %{error: "url is empty"}} =
               Host.call(
                 "v14-log-error",
                 "setup",
                 setup_payload("manual", %{"url" => "", "token" => ""}),
                 handler: :setup
               )

      assert end_marker("v14-log-error").metadata["detail"] == "step=manual body=form"
      refute logged_text("v14-log-error") =~ "url is empty"
    end

    test "a check-health marker names only the status" do
      start("v14-log-health", "host_v15_fixture.wasm")

      assert {:ok, _} =
               Host.call("v14-log-health", "check-health", %{}, handler: :check_health)

      detail = end_marker("v14-log-health").metadata["detail"]
      assert detail == "status=degraded"
      refute logged_text("v14-log-health") =~ "fixture degraded"
    end
  end

  test "setup and check-health are unsupported on an older guest" do
    start("v13-setup", "host_fns_fixture.wasm")

    assert {:error, %Error{type: :unsupported}} =
             Host.call("v13-setup", "setup", setup_payload("start"), handler: :setup)

    assert {:error, %Error{type: :unsupported}} =
             Host.call("v13-setup", "check-health", %{}, handler: :check_health)
  end

  test "1.5 imports are linked (stub bodies until their tasks land)" do
    start("v14-stubs", "host_v15_fixture.wasm")

    assert {:error, %Error{type: :guest_error, message: "links_list error: " <> _}} =
             Host.call("v14-stubs", "handle", %{"event" => "links_list"})
  end
end
