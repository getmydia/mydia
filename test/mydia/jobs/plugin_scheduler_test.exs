defmodule Mydia.Jobs.PluginSchedulerTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures

  alias Mydia.Jobs.PluginScheduler
  alias Mydia.Plugins.Connections
  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Instance
  alias Mydia.Plugins.Instances
  alias Mydia.Repo
  alias Mydia.Settings

  # Creates a plugin config plus its default instance. opts: :interval (manifest
  # schedule), :granted (schedule:interval granted), :last (instance
  # last_scheduled_at), :failures (instance schedule_failures).
  defp install!(slug, opts) do
    interval = Keyword.get(opts, :interval, 5)
    granted? = Keyword.get(opts, :granted, true)

    manifest = %{
      "slug" => slug,
      "name" => slug,
      "version" => "1.0.0",
      "capabilities" => %{
        "events:subscribe" => ["media_item.added"],
        "schedule:interval" => [],
        "users:connections" => []
      },
      "schedule" => %{"interval_minutes" => interval}
    }

    granted =
      if granted?,
        do: %{"schedule:interval" => [], "users:connections" => []},
        else: %{"users:connections" => []}

    {:ok, config} =
      Settings.create_plugin_config(%{
        slug: slug,
        name: slug,
        version: "1.0.0",
        source_url: "test",
        manifest: manifest,
        granted_capabilities: granted,
        enabled: true
      })

    attrs =
      [last_scheduled_at: opts[:last], schedule_failures: opts[:failures] || 0]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    slug |> Instances.default_instance() |> Ecto.Changeset.change(attrs) |> Repo.update!()
    config
  end

  defp reload_instance(slug), do: Repo.get!(Instance, Instances.default_instance(slug).id)

  # An invoker that records the {slug, instance_id} it was asked to run.
  defp recording_invoker(test_pid, result) do
    fn slug, instance_id ->
      send(test_pid, {:invoked, slug, instance_id})
      result
    end
  end

  test "effective_interval doubles with failures up to a cap" do
    assert PluginScheduler.effective_interval(5, 0) == 5
    assert PluginScheduler.effective_interval(5, 1) == 10
    assert PluginScheduler.effective_interval(5, 2) == 20
    assert PluginScheduler.effective_interval(5, 99) == 5 * 16
  end

  test "a never-run instance is due and gets invoked with its id" do
    install!("p", last: nil)
    id = Instances.default_instance("p").id
    PluginScheduler.tick(DateTime.utc_now(), recording_invoker(self(), {:ok, %{}}))
    assert_received {:invoked, "p", ^id}
  end

  test "each enabled instance of a plugin keeps its own clock" do
    install!("p", last: DateTime.utc_now())
    {:ok, due} = Instances.create("p", %{name: "Second"})
    {:ok, off} = Instances.create("p", %{name: "Off", enabled: false})

    PluginScheduler.tick(DateTime.utc_now(), recording_invoker(self(), {:ok, %{}}))

    due_id = due.id
    off_id = off.id
    assert_received {:invoked, "p", ^due_id}
    refute_received {:invoked, "p", ^off_id}
    refute_received {:invoked, "p", _other}
  end

  test "a recently-run instance is not due" do
    install!("p", interval: 30, last: DateTime.add(DateTime.utc_now(), -1, :minute))
    PluginScheduler.tick(DateTime.utc_now(), recording_invoker(self(), {:ok, %{}}))
    refute_received {:invoked, "p", _}
  end

  test "a plugin without the schedule:interval grant never ticks (deny-by-default)" do
    install!("p", granted: false, last: nil)
    PluginScheduler.tick(DateTime.utc_now(), recording_invoker(self(), {:ok, %{}}))
    refute_received {:invoked, "p", _}
  end

  test "success writes last_scheduled_at and resets the failure counter" do
    install!("p", last: nil, failures: 3)
    PluginScheduler.tick(DateTime.utc_now(), recording_invoker(self(), {:ok, %{}}))

    instance = reload_instance("p")
    assert instance.schedule_failures == 0
    refute is_nil(instance.last_scheduled_at)
  end

  test "failure increments the backoff counter" do
    install!("p", last: nil, failures: 1)
    PluginScheduler.tick(DateTime.utc_now(), fn _, _ -> {:error, :boom} end)
    assert reload_instance("p").schedule_failures == 2
  end

  test "a busy instance is skipped, leaving its bookkeeping untouched" do
    install!("p", last: nil, failures: 2)

    PluginScheduler.tick(DateTime.utc_now(), fn _, _ ->
      {:error, %Error{type: :busy, message: "in flight"}}
    end)

    instance = reload_instance("p")
    assert is_nil(instance.last_scheduled_at)
    assert instance.schedule_failures == 2
  end

  test "backoff delays the next tick for a failing instance" do
    install!("p", interval: 5, last: DateTime.add(DateTime.utc_now(), -10, :minute), failures: 2)

    PluginScheduler.tick(DateTime.utc_now(), recording_invoker(self(), {:ok, %{}}))
    refute_received {:invoked, "p", _}

    reload_instance("p")
    |> Ecto.Changeset.change(last_scheduled_at: DateTime.add(DateTime.utc_now(), -25, :minute))
    |> Repo.update!()

    PluginScheduler.tick(DateTime.utc_now(), recording_invoker(self(), {:ok, %{}}))
    assert_received {:invoked, "p", _}
  end

  test "connections_invalid in a result errors only active connections" do
    install!("p", last: nil)
    user = user_fixture()
    {:ok, _} = Connections.connect("p", user.id, %{access_token: "t"})

    result = {:ok, %{"connections_invalid" => [user.id, "bogus-not-connected"]}}
    PluginScheduler.tick(DateTime.utc_now(), recording_invoker(self(), result))

    assert Connections.get("p", user.id).status == "error"
  end

  test "a disabled plugin never ticks" do
    config = install!("p", last: nil)
    config |> Ecto.Changeset.change(enabled: false) |> Repo.update!()

    PluginScheduler.tick(DateTime.utc_now(), recording_invoker(self(), {:ok, %{}}))
    refute_received {:invoked, "p", _}
  end
end
