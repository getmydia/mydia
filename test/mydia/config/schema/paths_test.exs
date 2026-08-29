defmodule Mydia.Config.Schema.PathsTest do
  use ExUnit.Case, async: true

  alias Mydia.Config.Schema.Paths

  describe "overlay_keys/0" do
    test "includes every leaf of an embeds_one section" do
      keys = Paths.overlay_keys()

      assert "server.port" in keys
      assert "auth.oidc_enabled" in keys
      assert "media.movies_path" in keys
      assert "streaming.audio_language" in keys
    end

    test "excludes embeds_many sections, which have their own tables" do
      keys = Paths.overlay_keys()

      refute Enum.any?(keys, &String.starts_with?(&1, "indexers."))
      refute Enum.any?(keys, &String.starts_with?(&1, "library_paths."))
      refute Enum.any?(keys, &String.starts_with?(&1, "download_clients."))
    end

    test "excludes the database section, which is read before the db layer exists" do
      refute Enum.any?(Paths.overlay_keys(), &String.starts_with?(&1, "database."))
    end
  end

  describe "direct?/1 and known?/1" do
    test "the five direct-lookup keys are known but are not overlay keys" do
      for key <- [
            "crash_reporting.enabled",
            "feedback.enabled",
            "library.auto_repair_enabled",
            "library.auto_repair_threshold",
            "media.default_quality_profile_id"
          ] do
        assert Paths.direct?(key), "#{key} should be a direct-lookup key"
        assert Paths.known?(key), "#{key} should be known"
        refute key in Paths.overlay_keys(), "#{key} should not be an overlay key"
      end
    end

    test "an invented key is neither" do
      refute Paths.known?("server.nonexistent")
      refute Paths.direct?("server.nonexistent")
    end
  end

  describe "cast_overlay/2" do
    test "casts a value to the field's declared type" do
      assert {:ok, [:server, :port], 8080} = Paths.cast_overlay("server.port", "8080")
      assert {:ok, [:auth, :oidc_enabled], true} = Paths.cast_overlay("auth.oidc_enabled", "true")
    end

    test "does not guess a type the field did not declare" do
      # A string field holding digits stays a string. Inferring the type from
      # the value's shape put an integer into a path field.
      assert {:ok, [:media, :movies_path], "2024"} =
               Paths.cast_overlay("media.movies_path", "2024")
    end

    test "splits a comma-separated list into an array field" do
      assert {:ok, [:streaming, :audio_language], ["en", "fr"]} =
               Paths.cast_overlay("streaming.audio_language", "en, fr")
    end

    test "treats an empty or nil value as unset" do
      # media.default_quality_profile_id is deliberately persisted with an empty
      # value to mean "cleared", so empty must not be an error.
      assert {:ok, [:server, :url_host], nil} = Paths.cast_overlay("server.url_host", "")
      assert {:ok, [:server, :url_host], nil} = Paths.cast_overlay("server.url_host", nil)
    end

    test "reports an uncastable value without raising" do
      assert {:error, reason} = Paths.cast_overlay("server.port", "abc")
      assert reason =~ "server.port"
    end

    test "reports an unknown key without raising" do
      assert {:error, reason} = Paths.cast_overlay("server.nonexistent", "1")
      assert reason =~ "unknown"
    end

    test "reports a direct-lookup key as :direct, not as an error" do
      assert :direct = Paths.cast_overlay("crash_reporting.enabled", "true")
      assert :direct = Paths.cast_overlay("media.default_quality_profile_id", "")
    end
  end
end
