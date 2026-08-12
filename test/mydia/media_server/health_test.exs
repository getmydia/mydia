defmodule Mydia.MediaServer.HealthTest do
  use Mydia.DataCase, async: false

  alias Mydia.MediaServer.Health
  alias Mydia.Settings

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass}
  end

  defp jellyfin_config(bypass, attrs \\ %{}) do
    {:ok, config} =
      Settings.create_media_server_config(
        Map.merge(
          %{
            name: "Test Jellyfin",
            type: :jellyfin,
            url: "http://localhost:#{bypass.port}",
            token: "api-key",
            enabled: true,
            connection_settings: %{}
          },
          attrs
        )
      )

    config
  end

  describe "check_health/2" do
    test "reports healthy when the server answers", %{bypass: bypass} do
      config = jellyfin_config(bypass)

      Bypass.expect_once(bypass, "GET", "/System/Info", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"Version":"10.9.0"}))
      end)

      assert {:ok, health} = Health.check_health(config.id, force: true)
      assert health.status == :healthy
      assert health.error == nil
      assert %DateTime{} = health.checked_at
    end

    test "reports unhealthy with the error message when auth fails", %{bypass: bypass} do
      config = jellyfin_config(bypass)

      Bypass.expect_once(bypass, "GET", "/System/Info", fn conn ->
        Plug.Conn.resp(conn, 401, "")
      end)

      assert {:ok, health} = Health.check_health(config.id, force: true)
      assert health.status == :unhealthy
      assert health.error =~ "Authentication failed"
    end

    test "returns not_found for an unknown config id" do
      assert {:error, :not_found} = Health.check_health(Ecto.UUID.generate(), force: true)
    end
  end

  describe "status_map/1" do
    test "reports disabled servers as :disabled without a network call", %{bypass: bypass} do
      config = jellyfin_config(bypass, %{enabled: false})
      # Taking the server down proves the disabled path performs no I/O.
      Bypass.down(bypass)

      assert Health.status_map([config])[config.id].status == :disabled
    end

    test "reports :unknown for an enabled server that has never been checked", %{bypass: bypass} do
      config = jellyfin_config(bypass)

      assert Health.status_map([config])[config.id].status == :unknown
    end
  end
end
