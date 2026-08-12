defmodule MydiaWeb.AdminMediaServersLive.ComponentsTest do
  use ExUnit.Case, async: true

  # Only `render_component/2` is needed here, and importing `render/1` alongside
  # the local helpers below is noise. Matches franchise_components_test.exs.
  import Phoenix.LiveViewTest, except: [render: 1]

  alias Mydia.Settings.MediaServerConfig
  alias MydiaWeb.AdminMediaServersLive.Components

  defp server(attrs \\ %{}) do
    struct!(
      %MediaServerConfig{
        id: "11111111-1111-1111-1111-111111111111",
        name: "Storage",
        type: :plex,
        enabled: true,
        url: "http://localhost:32400",
        token: "tok",
        connection_settings: %{}
      },
      attrs
    )
  end

  defp render_tab(servers, health) do
    render_component(&Components.media_servers_tab/1, %{
      media_servers: servers,
      media_server_health: health,
      last_runs: %{}
    })
  end

  describe "health status" do
    test "an unhealthy server renders its error as text" do
      s = server()

      html = render_tab([s], %{s.id => %{status: :unhealthy, error: "connection refused"}})

      assert html =~ ~s(data-test="health-error")
      assert html =~ "connection refused"
    end

    test "a healthy server renders no error line" do
      s = server()

      html = render_tab([s], %{s.id => %{status: :healthy}})

      refute html =~ ~s(data-test="health-error")
    end

    test "an unhealthy server with no error detail renders no error line" do
      s = server()

      html = render_tab([s], %{s.id => %{status: :unhealthy}})

      refute html =~ ~s(data-test="health-error")
    end
  end
end
