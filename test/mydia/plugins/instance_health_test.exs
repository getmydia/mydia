defmodule Mydia.Plugins.InstanceHealthTest do
  # async: false: writes :persistent_term (the host's contract memo) and owns a
  # named ETS table.
  use Mydia.DataCase, async: false

  alias Mydia.Plugins.InstanceHealth
  alias Mydia.Plugins.Instances
  alias Mydia.Settings

  @slug "health_tester"

  setup do
    {:ok, _} =
      Settings.create_plugin_config(%{
        slug: @slug,
        name: @slug,
        version: "1.0.0",
        source_url: "test",
        manifest: %{
          "slug" => @slug,
          "name" => @slug,
          "version" => "1.0.0",
          "capabilities" => %{"events:subscribe" => ["media_item.added"]}
        },
        granted_capabilities: %{},
        enabled: true
      })

    :persistent_term.put({Mydia.Plugins.Host, :contract, @slug}, :v14)
    on_exit(fn -> :persistent_term.erase({Mydia.Plugins.Host, :contract, @slug}) end)

    start_supervised!({InstanceHealth, check_on_start: false})
    {:ok, instance} = Instances.create(@slug, %{name: "Den"})
    {:ok, instance: instance}
  end

  defp checker(reply), do: fn _slug, _id -> reply end

  test "a forced check caches the guest's answer", %{instance: i} do
    reply = {:ok, %{status: :unauthorized, message: "token revoked", action: :reconnect}}

    assert {:ok, %{status: :unauthorized, message: "token revoked", action: :reconnect}} =
             InstanceHealth.check(i.id, force: true, checker: checker(reply))

    assert %{status: :unauthorized} = InstanceHealth.status_map([i])[i.id]
  end

  test "WIT-spelled actions are normalized", %{instance: i} do
    reply = {:ok, %{status: :unreachable, message: nil, action: :"confirm-endpoints"}}

    assert {:ok, %{action: :confirm_endpoints}} =
             InstanceHealth.check(i.id, force: true, checker: checker(reply))
  end

  test "a guest Err reads as unreachable with the guest's message", %{instance: i} do
    err =
      {:error, Mydia.Plugins.Error.new(:guest_error, "check-health error: Network(\"refused\")")}

    assert {:ok, %{status: :unreachable, message: "check-health error: Network(\"refused\")"}} =
             InstanceHealth.check(i.id, force: true, checker: checker(err))
  end

  test "an :unsupported invocation error reads as :unsupported", %{instance: i} do
    err = {:error, Mydia.Plugins.Error.new(:unsupported, "plugin does not declare setup")}

    assert {:ok, %{status: :unsupported}} =
             InstanceHealth.check(i.id, force: true, checker: checker(err))
  end

  test "an unforced check returns the cache without calling the guest", %{instance: i} do
    {:ok, _} = InstanceHealth.check(i.id, force: true, checker: checker({:ok, %{status: :ok}}))
    boom = fn _, _ -> raise "must not be called" end
    assert {:ok, %{status: :ok}} = InstanceHealth.check(i.id, checker: boom)
  end

  test "status_map is :unknown before any check and :disabled for a disabled instance",
       %{instance: i} do
    assert %{status: :unknown} = InstanceHealth.status_map([i])[i.id]
    {:ok, off} = Instances.update(i, %{enabled: false})
    assert %{status: :disabled} = InstanceHealth.status_map([off])[off.id]
  end

  test "a pre-1.4 plugin reports :unsupported without calling the guest", %{instance: i} do
    :persistent_term.put({Mydia.Plugins.Host, :contract, @slug}, :v13)
    boom = fn _, _ -> raise "must not be called" end

    assert {:ok, %{status: :unsupported}} =
             InstanceHealth.check(i.id, force: true, checker: boom)
  end

  test "an unknown instance is not_found" do
    assert {:error, :not_found} = InstanceHealth.check(Ecto.UUID.generate(), force: true)
  end
end
