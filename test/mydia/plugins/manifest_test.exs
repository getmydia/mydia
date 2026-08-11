defmodule Mydia.Plugins.ManifestTest do
  use ExUnit.Case, async: true

  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Manifest
  alias Mydia.Plugins.Plugin

  defp valid_map(overrides \\ %{}) do
    Map.merge(
      %{
        "slug" => "webhook-notifier",
        "name" => "Webhook Notifier",
        "version" => "1.0.0",
        "description" => "Posts events to a webhook",
        "author" => "Mydia",
        "capabilities" => %{
          "events:subscribe" => ["media_item.added", "download.completed"],
          "net:http" => ["discord.com"]
        }
      },
      overrides
    )
  end

  describe "parse/1" do
    test "parses a valid manifest with capabilities and event subscriptions" do
      assert {:ok, %Manifest{} = manifest} = Manifest.parse(valid_map())
      assert manifest.slug == "webhook-notifier"
      assert manifest.name == "Webhook Notifier"
      assert manifest.version == "1.0.0"
      assert manifest.entrypoint == "handle"
      assert manifest.events == ["media_item.added", "download.completed"]
      assert manifest.capabilities["net:http"] == ["discord.com"]
    end

    test "accepts a JSON string" do
      assert {:ok, %Manifest{slug: "webhook-notifier"}} =
               Manifest.parse(Jason.encode!(valid_map()))
    end

    test "rejects invalid JSON" do
      assert {:error, %Error{type: :invalid_manifest}} = Manifest.parse("{not json")
    end

    test "rejects a manifest missing required fields" do
      assert {:error, %Error{type: :invalid_manifest, message: msg}} =
               Manifest.parse(Map.delete(valid_map(), "version"))

      assert msg =~ "version"
    end

    test "rejects an event outside the v1 catalog" do
      map = valid_map(%{"capabilities" => %{"events:subscribe" => ["media_item.exploded"]}})
      assert {:error, %Error{type: :invalid_manifest, message: msg}} = Manifest.parse(map)
      assert msg =~ "media_item.exploded"
    end

    test "rejects an unknown capability class" do
      map =
        valid_map(%{
          "capabilities" => %{"events:subscribe" => ["media_item.added"], "fs:write" => ["/tmp"]}
        })

      assert {:error, %Error{type: :invalid_manifest, message: msg}} = Manifest.parse(map)
      assert msg =~ "fs:write"
    end

    test "parses data:read with a valid namespace (available in v1)" do
      map =
        valid_map(%{
          "capabilities" => %{
            "events:subscribe" => ["media_item.added"],
            "net:http" => ["discord.com"],
            "data:read" => ["media_item"]
          }
        })

      assert {:ok, %Manifest{capabilities: caps}} = Manifest.parse(map)
      assert caps["data:read"] == ["media_item"]
    end

    test "accepts library_item as a data:read namespace" do
      manifest = %{
        "slug" => "t",
        "name" => "T",
        "version" => "1.0.0",
        "capabilities" => %{
          "events:subscribe" => ["media_item.added"],
          "data:read" => ["library_item"]
        }
      }

      assert {:ok, _} = Mydia.Plugins.Manifest.parse(manifest)
    end

    test "rejects a data:read namespace outside the v1 catalog" do
      map =
        valid_map(%{
          "capabilities" => %{
            "events:subscribe" => ["media_item.added"],
            "data:read" => ["secrets"]
          }
        })

      assert {:error, %Error{type: :invalid_manifest, message: msg}} = Manifest.parse(map)
      assert msg =~ "secrets"
    end

    test "accepts surfaces:write with the playback:watched vocabulary" do
      map =
        valid_map(%{
          "capabilities" => %{
            "events:subscribe" => ["media_item.added"],
            "surfaces:write" => ["playback:watched"]
          }
        })

      assert {:ok, %Manifest{capabilities: caps}} = Manifest.parse(map)
      assert caps["surfaces:write"] == ["playback:watched"]
    end

    test "rejects an unknown surfaces:write surface" do
      map =
        valid_map(%{
          "capabilities" => %{
            "events:subscribe" => ["media_item.added"],
            "surfaces:write" => ["recommended"]
          }
        })

      assert {:error, %Error{type: :invalid_manifest, message: msg}} = Manifest.parse(map)
      assert msg =~ "recommended"
    end

    test "rejects a net:http wildcard hostname (KTD5 exact-match rule)" do
      map =
        valid_map(%{
          "capabilities" => %{
            "events:subscribe" => ["media_item.added"],
            "net:http" => ["*.discord.com"]
          }
        })

      assert {:error, %Error{type: :invalid_manifest, message: msg}} = Manifest.parse(map)
      assert msg =~ "wildcard"
    end

    test "rejects a net:http host with a port (gate matches bare hostnames)" do
      map =
        valid_map(%{
          "capabilities" => %{
            "events:subscribe" => ["media_item.added"],
            "net:http" => ["discord.com:443"]
          }
        })

      assert {:error, %Error{type: :invalid_manifest, message: msg}} = Manifest.parse(map)
      assert msg =~ "bare hostname"
    end

    test "rejects a net:http host with a scheme/path" do
      map =
        valid_map(%{
          "capabilities" => %{
            "events:subscribe" => ["media_item.added"],
            "net:http" => ["https://discord.com/api"]
          }
        })

      assert {:error, %Error{type: :invalid_manifest, message: msg}} = Manifest.parse(map)
      assert msg =~ "bare hostname"
    end

    test "rejects a net:http host with leading/trailing whitespace" do
      map =
        valid_map(%{
          "capabilities" => %{
            "events:subscribe" => ["media_item.added"],
            "net:http" => [" discord.com "]
          }
        })

      assert {:error, %Error{type: :invalid_manifest, message: msg}} = Manifest.parse(map)
      assert msg =~ "whitespace"
    end

    test "requires events:subscribe to be present" do
      map = valid_map(%{"capabilities" => %{"net:http" => ["discord.com"]}})
      assert {:error, %Error{type: :invalid_manifest}} = Manifest.parse(map)
    end

    test "requires at least one capability" do
      map = valid_map(%{"capabilities" => %{}})
      assert {:error, %Error{type: :invalid_manifest}} = Manifest.parse(map)
    end
  end

  describe "parse/1 min_host_version (R7)" do
    test "defaults to nil (no floor) when absent" do
      assert {:ok, %Manifest{min_host_version: nil}} = Manifest.parse(valid_map())
    end

    test "stores a valid semantic version" do
      assert {:ok, %Manifest{min_host_version: "1.2.0"}} =
               Manifest.parse(valid_map(%{"min_host_version" => "1.2.0"}))
    end

    test "rejects a non-semver value" do
      assert {:error, %Error{type: :invalid_manifest, message: msg}} =
               Manifest.parse(valid_map(%{"min_host_version" => "v1"}))

      assert msg =~ "min_host_version"
    end

    test "rejects a non-string value" do
      assert {:error, %Error{type: :invalid_manifest}} =
               Manifest.parse(valid_map(%{"min_host_version" => 1}))
    end
  end

  describe "parse/1 settings_schema" do
    defp schema_map(schema) do
      valid_map(%{"settings_schema" => schema})
    end

    test "parses a schema with url (host-granting), secret, and enum fields" do
      map =
        schema_map([
          %{
            "key" => "target",
            "type" => "enum",
            "label" => "Target",
            "options" => ["discord", "ntfy"]
          },
          %{
            "key" => "webhook_url",
            "type" => "url",
            "label" => "Server URL",
            "grants_host" => true
          },
          %{"key" => "ntfy_token", "type" => "secret", "label" => "Access token"}
        ])

      assert {:ok, %Manifest{settings_schema: schema}} = Manifest.parse(map)
      assert length(schema) == 3
      assert Manifest.host_granting_keys(schema) == ["webhook_url"]
    end

    test "defaults to an empty schema when absent (backward compatible)" do
      assert {:ok, %Manifest{settings_schema: []}} = Manifest.parse(valid_map())
    end

    test "host_granting_keys/1 works on a parsed manifest struct" do
      {:ok, manifest} =
        Manifest.parse(
          schema_map([%{"key" => "webhook_url", "type" => "url", "grants_host" => true}])
        )

      assert Manifest.host_granting_keys(manifest) == ["webhook_url"]
    end

    test "rejects grants_host on a non-url field" do
      map = schema_map([%{"key" => "secret_field", "type" => "secret", "grants_host" => true}])
      assert {:error, %Error{type: :invalid_manifest, message: msg}} = Manifest.parse(map)
      assert msg =~ "grants_host"
    end

    test "rejects an unknown field type" do
      map = schema_map([%{"key" => "weird", "type" => "datetime"}])
      assert {:error, %Error{type: :invalid_manifest, message: msg}} = Manifest.parse(map)
      assert msg =~ "datetime"
    end

    test "rejects an enum field with no options" do
      map = schema_map([%{"key" => "target", "type" => "enum"}])
      assert {:error, %Error{type: :invalid_manifest, message: msg}} = Manifest.parse(map)
      assert msg =~ "options"
    end

    test "rejects a blank field key" do
      map = schema_map([%{"key" => "", "type" => "string"}])
      assert {:error, %Error{type: :invalid_manifest, message: msg}} = Manifest.parse(map)
      assert msg =~ "key"
    end

    test "rejects duplicate field keys" do
      map =
        schema_map([
          %{"key" => "dup", "type" => "string"},
          %{"key" => "dup", "type" => "url"}
        ])

      assert {:error, %Error{type: :invalid_manifest, message: msg}} = Manifest.parse(map)
      assert msg =~ "unique"
    end

    test "rejects a non-list settings_schema" do
      map = schema_map(%{"key" => "x", "type" => "string"})
      assert {:error, %Error{type: :invalid_manifest, message: msg}} = Manifest.parse(map)
      assert msg =~ "list"
    end

    test "accepts a text field type" do
      map = schema_map([%{"key" => "body_template", "type" => "text", "label" => "Body"}])
      assert {:ok, %Manifest{settings_schema: [field]}} = Manifest.parse(map)
      assert field["type"] == "text"
    end

    test "accepts a field with a valid visible_when (string and list values)" do
      map =
        schema_map([
          %{"key" => "target", "type" => "enum", "options" => ["discord", "ntfy"]},
          %{"key" => "ntfy_tags", "type" => "string", "visible_when" => %{"target" => "ntfy"}},
          %{
            "key" => "extra",
            "type" => "string",
            "visible_when" => %{"target" => ["ntfy", "custom"]}
          }
        ])

      assert {:ok, %Manifest{settings_schema: schema}} = Manifest.parse(map)
      assert length(schema) == 3
    end

    test "rejects visible_when referencing an unknown setting key" do
      map =
        schema_map([
          %{"key" => "ntfy_tags", "type" => "string", "visible_when" => %{"nope" => "ntfy"}}
        ])

      assert {:error, %Error{type: :invalid_manifest, message: msg}} = Manifest.parse(map)
      assert msg =~ "visible_when"
      assert msg =~ "nope"
    end

    test "rejects a malformed visible_when value" do
      map =
        schema_map([
          %{"key" => "target", "type" => "enum", "options" => ["discord"]},
          %{"key" => "x", "type" => "string", "visible_when" => %{"target" => 5}}
        ])

      assert {:error, %Error{type: :invalid_manifest, message: msg}} = Manifest.parse(map)
      assert msg =~ "visible_when"
    end
  end

  describe "Plugin.from_manifest/2 (R5 deny-by-default)" do
    test "builds a descriptor that declares capabilities but grants none" do
      {:ok, manifest} = Manifest.parse(valid_map())
      plugin = Plugin.from_manifest(manifest)

      assert %Plugin{} = plugin
      assert plugin.slug == "webhook-notifier"
      assert plugin.events == ["media_item.added", "download.completed"]
      assert plugin.capabilities["net:http"] == ["discord.com"]

      # Parsing/building confers no active capability.
      assert plugin.granted_capabilities == %{}
      assert plugin.enabled == false
      refute Plugin.granted?(plugin, "net:http")
      assert Plugin.granted_http_hosts(plugin) == []
    end

    test "carries grants only when explicitly provided (e.g. from persisted config)" do
      {:ok, manifest} = Manifest.parse(valid_map())

      plugin =
        Plugin.from_manifest(manifest,
          granted_capabilities: %{"net:http" => ["discord.com"]},
          enabled: true,
          source: :index
        )

      assert Plugin.granted?(plugin, "net:http")
      assert Plugin.granted_http_hosts(plugin) == ["discord.com"]
      assert plugin.enabled
      assert plugin.source == :index
    end
  end

  describe "connection descriptor (U7)" do
    defp with_connection(connection, hosts \\ ["api.simkl.com", "simkl.com"]) do
      valid_map(%{
        "capabilities" => %{
          "events:subscribe" => ["media_item.added"],
          "net:http" => hosts,
          "users:connections" => []
        },
        "connection" => connection
      })
    end

    test "a valid oauth_device descriptor parses and is carried on the manifest" do
      conn = %{
        "type" => "oauth_device",
        "code_url" => "https://api.simkl.com/oauth/pin?client_id={client_id}",
        "poll_url" => "https://api.simkl.com/oauth/pin/{user_code}?client_id={client_id}",
        "verification_url" => "https://simkl.com/pin",
        "client_id" => "abc"
      }

      assert {:ok, %Manifest{connection: ^conn}} = Manifest.parse(with_connection(conn))
    end

    test "a URL whose host is not in net:http is rejected" do
      conn = %{
        "type" => "oauth_device",
        "code_url" => "https://evil.test/pin",
        "poll_url" => "https://api.simkl.com/oauth/pin/{user_code}"
      }

      assert {:error, %{type: :invalid_manifest, message: msg}} =
               Manifest.parse(with_connection(conn))

      assert msg =~ "net:http"
    end

    test "an unknown connection type is rejected" do
      conn = %{
        "type" => "magic",
        "code_url" => "https://api.simkl.com/pin",
        "poll_url" => "https://api.simkl.com/pin/x"
      }

      assert {:error, %{type: :invalid_manifest}} = Manifest.parse(with_connection(conn))
    end

    test "a missing required url is rejected" do
      conn = %{"type" => "oauth_device", "poll_url" => "https://api.simkl.com/pin/x"}

      assert {:error, %{type: :invalid_manifest, message: msg}} =
               Manifest.parse(with_connection(conn))

      assert msg =~ "code_url"
    end

    test "users:connections is an available capability class" do
      assert "users:connections" in Manifest.available_classes()
    end
  end

  describe "schedule descriptor (U4)" do
    defp with_schedule(schedule, extra_caps \\ %{"schedule:interval" => []}) do
      valid_map(%{
        "capabilities" => Map.merge(%{"events:subscribe" => ["media_item.added"]}, extra_caps),
        "schedule" => schedule
      })
    end

    test "a valid schedule parses and exposes the interval" do
      map = with_schedule(%{"interval_minutes" => 30})
      assert {:ok, %Manifest{} = manifest} = Manifest.parse(map)
      assert Manifest.schedule_interval_minutes(manifest) == 30
    end

    test "an interval below the floor is rejected" do
      map = with_schedule(%{"interval_minutes" => 1})

      assert {:error, %{type: :invalid_manifest, message: msg}} = Manifest.parse(map)
      assert msg =~ "at least #{Manifest.min_schedule_interval()}"
    end

    test "a schedule without the schedule:interval capability is rejected" do
      map = with_schedule(%{"interval_minutes" => 30}, %{})

      assert {:error, %{type: :invalid_manifest, message: msg}} = Manifest.parse(map)
      assert msg =~ "schedule:interval"
    end

    test "a non-integer interval is rejected" do
      map = with_schedule(%{"interval_minutes" => "soon"})
      assert {:error, %{type: :invalid_manifest}} = Manifest.parse(map)
    end

    test "no schedule means no interval" do
      assert {:ok, %Manifest{schedule: nil}} = Manifest.parse(valid_map())
      assert Manifest.schedule_interval_minutes(%Manifest{}) == nil
    end
  end
end
