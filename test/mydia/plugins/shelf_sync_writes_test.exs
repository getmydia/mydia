defmodule Mydia.Plugins.ShelfSyncWritesTest do
  # The older sync writes are gated by grant, not by handler. A shelf fill has
  # nobody to approve a change, so they must be refused there even when the
  # plugin holds the matching grant.
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures

  alias Mydia.Plugins.HostFunctions
  alias Mydia.Plugins.Plugin
  alias Mydia.Plugins.Registry

  @slug "shelf-sync-writer"
  @namespace "mydia:plugin/host@1.6.0"
  @refusal "writes are not available during a shelf fill"

  setup do
    {:ok, _} =
      Registry.register(@slug, %Plugin{
        slug: @slug,
        name: "Sync Writer",
        enabled: true,
        granted_capabilities: %{
          "surfaces:shelf" => [],
          "surfaces:write" => ["playback:watched", "collections:favorite"]
        }
      })

    on_exit(fn -> Registry.unregister(@slug) end)

    {:ok, user: user_fixture()}
  end

  defp closures(handler, user) do
    ctx = %{
      slug: @slug,
      instance_id: nil,
      invocation_id: "i",
      test_run: false,
      handler: handler,
      acting_user_id: user.id,
      role: user.role,
      session_id: nil
    }

    imports = HostFunctions.imports_for(@slug).(ctx) |> Map.fetch!(@namespace)

    for name <- ~w(ensure-watched set-watch-state ensure-favorite), into: %{} do
      {:fn, fun} = Map.fetch!(imports, name)
      {name, fun}
    end
  end

  defp target(user), do: %{"user-id": user.id, "tmdb-id": 12_345, watched: true}

  test "every sync write is denied during a fill", %{user: user} do
    for {name, fun} <- closures(:fill_shelf, user) do
      assert {:error, {:denied, @refusal}} == fun.(target(user)),
             "#{name} was not refused during a fill"
    end
  end

  test "other handlers are not refused by the fill check", %{user: user} do
    for {name, fun} <- closures(:on_event, user) do
      refute match?({:error, {:denied, @refusal}}, fun.(target(user))),
             "#{name} was refused outside a fill"
    end
  end
end
