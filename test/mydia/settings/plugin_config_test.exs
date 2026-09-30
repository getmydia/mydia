defmodule Mydia.Settings.PluginConfigTest do
  # async: false — the regression test injects the global :runtime_config
  # application env. We never call System.put_env (Postgres async-leak rule).
  use Mydia.DataCase, async: false

  alias Mydia.Settings
  alias Mydia.Settings.PluginConfig

  @grants %{"net:http" => ["discord.com"], "events:subscribe" => ["media_item.added"]}
  @hash Base.encode16(:crypto.hash(:sha256, "package-bytes"), case: :lower)

  describe "DB CRUD round-trip (R8)" do
    test "create / read / update / enable" do
      assert {:ok, %PluginConfig{} = config} =
               Settings.create_plugin_config(%{
                 slug: "webhook-notifier",
                 name: "Webhook Notifier",
                 version: "1.0.0",
                 settings: %{"webhook_url" => "https://discord.com/api/webhooks/x"},
                 granted_capabilities: @grants,
                 integrity_hash: @hash
               })

      refute config.enabled

      fetched = Settings.get_plugin_config_by_slug("webhook-notifier")
      assert fetched.id == config.id

      assert {:ok, updated} = Settings.update_plugin_config(fetched, %{enabled: true})
      assert updated.enabled

      assert Enum.any?(
               Settings.list_plugin_configs(),
               &(&1.slug == "webhook-notifier" and &1.enabled)
             )
    end

    test "upsert updates an existing row by slug" do
      {:ok, _} = Settings.create_plugin_config(%{slug: "p", name: "P", version: "1.0.0"})
      {:ok, upserted} = Settings.upsert_plugin_config(%{slug: "p", name: "P", version: "2.0.0"})

      assert upserted.version == "2.0.0"
      assert length(Enum.filter(Settings.list_plugin_configs(), &(&1.slug == "p"))) == 1
    end

    test "rejects an invalid slug" do
      assert {:error, changeset} =
               Settings.create_plugin_config(%{slug: "Bad Slug!", name: "x"})

      assert %{slug: _} = errors_on(changeset)
    end
  end

  describe "granted_capabilities + integrity_hash persistence (dual-engine safe)" do
    test "granted_capabilities round-trips as a map structure" do
      {:ok, _} =
        Settings.create_plugin_config(%{
          slug: "grants",
          name: "Grants",
          granted_capabilities: @grants
        })

      reloaded = Settings.get_plugin_config_by_slug("grants")
      assert reloaded.granted_capabilities == @grants
      assert is_map(reloaded.granted_capabilities)
    end

    test "integrity_hash stores and round-trips as ASCII hex (no UTF-8 failure)" do
      {:ok, _} =
        Settings.create_plugin_config(%{slug: "hashed", name: "Hashed", integrity_hash: @hash})

      reloaded = Settings.get_plugin_config_by_slug("hashed")
      assert reloaded.integrity_hash == @hash
      assert String.match?(reloaded.integrity_hash, ~r/^[0-9a-f]+$/)
    end
  end

  describe "list_plugin_configs/1" do
    test "returns DB rows only, even when the runtime config lists plugin_installs" do
      base = Mydia.Config.Schema.defaults()
      previous = Application.get_env(:mydia, :runtime_config)

      Application.put_env(:mydia, :runtime_config, %{
        base
        | plugin_installs: [%Mydia.Config.Schema.PluginInstall{slug: "shared", name: "From Env"}]
      })

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:mydia, :runtime_config)
          value -> Application.put_env(:mydia, :runtime_config, value)
        end
      end)

      {:ok, db} = Settings.create_plugin_config(%{slug: "shared", name: "From DB"})

      assert [%PluginConfig{id: id, name: "From DB"}] =
               Enum.filter(Settings.list_plugin_configs(), &(&1.slug == "shared"))

      assert id == db.id
    end
  end
end
