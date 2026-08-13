defmodule Mydia.Subtitles.Client.MetadataRelayTest do
  # Not async: these tests clear and restore the global application and system
  # environment that production relay configuration is read from. ExUnit runs
  # sync modules serially after every async module has finished, so no
  # concurrent test can observe the cleared window.
  use ExUnit.Case, async: false

  alias Mydia.Subtitles.Client.MetadataRelay

  setup do
    original = %{
      subtitle_app: Application.get_env(:mydia, :subtitle_relay_url),
      metadata_app: Application.get_env(:mydia, :metadata_relay_url),
      metadata_env: System.get_env("METADATA_RELAY_URL"),
      subtitle_env: System.get_env("SUBTITLE_RELAY_URL")
    }

    Application.delete_env(:mydia, :subtitle_relay_url)
    Application.delete_env(:mydia, :metadata_relay_url)
    System.delete_env("METADATA_RELAY_URL")
    System.delete_env("SUBTITLE_RELAY_URL")

    on_exit(fn ->
      restore_app_env(:subtitle_relay_url, original.subtitle_app)
      restore_app_env(:metadata_relay_url, original.metadata_app)
      restore_system_env("METADATA_RELAY_URL", original.metadata_env)
      restore_system_env("SUBTITLE_RELAY_URL", original.subtitle_env)
    end)

    :ok
  end

  describe "base_url/0" do
    # The registry enables the relay provider by default (default_enabled: true)
    # on the stated promise that it needs no setup, and every other relay
    # consumer reaches the service through Mydia.Metadata.metadata_relay_url/0,
    # which carries the https://relay.mydia.dev default. This client resolved
    # its own URL and ended the chain with "", so a default install -- one that
    # never sets METADATA_RELAY_URL, which is the normal self-hosted case --
    # failed every subtitle search with :metadata_relay_not_configured while
    # metadata lookups on the same install worked fine.
    test "falls back to the shared relay default when nothing is configured" do
      assert MetadataRelay.base_url() == Mydia.Metadata.metadata_relay_url()
      refute MetadataRelay.base_url() == ""
    end

    test "prefers the subtitle-specific application config over everything else" do
      Application.put_env(:mydia, :subtitle_relay_url, "http://subtitle-app.test")
      Application.put_env(:mydia, :metadata_relay_url, "http://metadata-app.test")
      System.put_env("METADATA_RELAY_URL", "http://metadata-env.test")
      System.put_env("SUBTITLE_RELAY_URL", "http://subtitle-env.test")

      assert MetadataRelay.base_url() == "http://subtitle-app.test"
    end

    test "prefers the general application config over the environment" do
      Application.put_env(:mydia, :metadata_relay_url, "http://metadata-app.test")
      System.put_env("METADATA_RELAY_URL", "http://metadata-env.test")

      assert MetadataRelay.base_url() == "http://metadata-app.test"
    end

    # Guards the existing precedence: METADATA_RELAY_URL has always outranked
    # SUBTITLE_RELAY_URL here, and adding the default must not quietly reorder
    # the two for an operator who sets both.
    test "prefers METADATA_RELAY_URL over SUBTITLE_RELAY_URL" do
      System.put_env("METADATA_RELAY_URL", "http://metadata-env.test")
      System.put_env("SUBTITLE_RELAY_URL", "http://subtitle-env.test")

      assert MetadataRelay.base_url() == "http://metadata-env.test"
    end

    test "uses SUBTITLE_RELAY_URL when it is the only thing set" do
      System.put_env("SUBTITLE_RELAY_URL", "http://subtitle-env.test")

      assert MetadataRelay.base_url() == "http://subtitle-env.test"
    end
  end

  describe "search/2 on an unconfigured install" do
    # The production symptom this fix targets: the search short-circuited
    # before any request was made, and the provider chain surfaced it as
    # {:all_providers_failed, [{"Mydia Relay", "Search failed:
    # :metadata_relay_not_configured"}]}.
    test "reaches the default relay instead of reporting itself unconfigured" do
      bypass = Bypass.open()
      System.put_env("METADATA_RELAY_URL", "http://localhost:#{bypass.port}")

      Bypass.expect_once(bypass, "POST", "/api/v1/subtitles/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"subtitles" => []}))
      end)

      assert {:ok, %{"subtitles" => []}} =
               MetadataRelay.search(%{imdb_id: "0133093", languages: "en"})
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:mydia, key)
  defp restore_app_env(key, value), do: Application.put_env(:mydia, key, value)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
