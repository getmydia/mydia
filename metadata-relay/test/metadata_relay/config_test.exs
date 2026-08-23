defmodule MetadataRelay.ConfigTest do
  @moduledoc """
  Regression tests for T-259..T-262: `DASHBOARD_USERNAME`/`DASHBOARD_PASSWORD`
  were read in `config/runtime.exs` via the bare `System.get_env(name) ||
  raise(...)` pattern. `System.get_env/1` returns `""`, not `nil`, for a
  variable explicitly set to an empty string, and `""` is truthy in Elixir,
  so `DASHBOARD_USERNAME=""`/`DASHBOARD_PASSWORD=""` resolved to
  `dashboard_auth: [username: "", password: ""]` even in `:prod` -- and
  `Plug.BasicAuth` does not itself reject an empty configured credential
  (its own moduledoc: "may be empty strings"), so `Authorization: Basic
  Og==` (base64 of `":"`) then authenticated as anyone.
  """

  use ExUnit.Case, async: true

  alias MetadataRelay.Config

  describe "get_non_blank/1" do
    test "returns nil for an unset variable" do
      System.delete_env("MRELAY_CONFIG_TEST_VAR")
      assert Config.get_non_blank("MRELAY_CONFIG_TEST_VAR") == nil
    end

    test "returns nil for an explicitly empty string" do
      System.put_env("MRELAY_CONFIG_TEST_VAR", "")
      on_exit(fn -> System.delete_env("MRELAY_CONFIG_TEST_VAR") end)

      assert Config.get_non_blank("MRELAY_CONFIG_TEST_VAR") == nil
    end

    test "returns nil for a whitespace-only string" do
      System.put_env("MRELAY_CONFIG_TEST_VAR", "   ")
      on_exit(fn -> System.delete_env("MRELAY_CONFIG_TEST_VAR") end)

      assert Config.get_non_blank("MRELAY_CONFIG_TEST_VAR") == nil
    end

    test "returns the trimmed value when set to something real" do
      System.put_env("MRELAY_CONFIG_TEST_VAR", "  hunter2  ")
      on_exit(fn -> System.delete_env("MRELAY_CONFIG_TEST_VAR") end)

      assert Config.get_non_blank("MRELAY_CONFIG_TEST_VAR") == "hunter2"
    end
  end

  describe "fetch_credential!/3" do
    setup do
      on_exit(fn -> System.delete_env("MRELAY_CONFIG_TEST_CRED") end)
      :ok
    end

    test "raises in :prod when the env var is unset" do
      System.delete_env("MRELAY_CONFIG_TEST_CRED")

      assert_raise RuntimeError, ~r/MRELAY_CONFIG_TEST_CRED not set/, fn ->
        Config.fetch_credential!("MRELAY_CONFIG_TEST_CRED", :prod, "admin")
      end
    end

    # The exact scenario the finding describes: an operator (or a templated
    # manifest, or a secret store) sets the variable to an empty string
    # rather than leaving it unset.
    test "raises in :prod when the env var is set to an empty string" do
      System.put_env("MRELAY_CONFIG_TEST_CRED", "")

      assert_raise RuntimeError, ~r/MRELAY_CONFIG_TEST_CRED not set/, fn ->
        Config.fetch_credential!("MRELAY_CONFIG_TEST_CRED", :prod, "admin")
      end
    end

    test "raises in :prod when the env var is whitespace-only" do
      System.put_env("MRELAY_CONFIG_TEST_CRED", "   ")

      assert_raise RuntimeError, ~r/MRELAY_CONFIG_TEST_CRED not set/, fn ->
        Config.fetch_credential!("MRELAY_CONFIG_TEST_CRED", :prod, "admin")
      end
    end

    test "falls back to the default outside :prod when unset or blank" do
      System.delete_env("MRELAY_CONFIG_TEST_CRED")
      assert Config.fetch_credential!("MRELAY_CONFIG_TEST_CRED", :dev, "admin") == "admin"

      System.put_env("MRELAY_CONFIG_TEST_CRED", "")
      assert Config.fetch_credential!("MRELAY_CONFIG_TEST_CRED", :dev, "admin") == "admin"
    end

    test "returns the real value when genuinely set, in any env" do
      System.put_env("MRELAY_CONFIG_TEST_CRED", "hunter2")

      assert Config.fetch_credential!("MRELAY_CONFIG_TEST_CRED", :prod, "admin") == "hunter2"
      assert Config.fetch_credential!("MRELAY_CONFIG_TEST_CRED", :dev, "admin") == "hunter2"
    end
  end
end
