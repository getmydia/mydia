defmodule MydiaWeb.UnhandledMessageTest do
  # Calls handle_info/2 directly rather than mounting. The catch-all never
  # touches the socket, so a bare struct is sufficient, and this avoids
  # DashboardLive's metadata-relay fetches at mount entirely.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Phoenix.LiveView.Socket

  @live_views [
    MydiaWeb.DashboardLive.Index,
    MydiaWeb.CalendarLive.Index,
    MydiaWeb.SearchLive.Index,
    MydiaWeb.DownloadsLive.Index,
    MydiaWeb.MediaLive.Index
  ]

  # The existing MediaLive.Index precedent logs the module name *without* the
  # MydiaWeb prefix. Match it rather than inventing a second format.
  defp short_name(module) do
    module |> Module.split() |> Enum.drop(1) |> Enum.join(".")
  end

  for module <- @live_views do
    test "#{inspect(module)} absorbs an unmatched message instead of crashing" do
      socket = %Socket{}
      module = unquote(module)

      log =
        capture_log(fn ->
          assert {:noreply, ^socket} =
                   module.handle_info({:totally_unexpected, :message}, socket)
        end)

      assert log =~ "Unhandled message in #{short_name(module)}"
    end
  end

  # `Mydia.Downloads.Grabber` broadcasts these three shapes on the "downloads"
  # topic alongside `{:download_updated, id}`. Only MediaLive.Show owns the
  # manual-search UI and needs to act on them; the other subscribers should
  # ignore them quietly rather than logging them as unhandled.
  @grab_silent_live_views [
    MydiaWeb.DashboardLive.Index,
    MydiaWeb.CalendarLive.Index,
    MydiaWeb.SearchLive.Index,
    MydiaWeb.DownloadsLive.Index
  ]

  @grab_messages [
    {:grab_completed, %{}},
    {:grab_failed, %{}},
    {:grab_duplicate, %{}}
  ]

  for module <- @grab_silent_live_views, grab_message <- @grab_messages do
    test "#{inspect(module)} ignores #{inspect(elem(grab_message, 0))} silently" do
      socket = %Socket{}
      module = unquote(module)
      grab_message = unquote(Macro.escape(grab_message))

      log =
        capture_log(fn ->
          assert {:noreply, ^socket} = module.handle_info(grab_message, socket)
        end)

      assert log == ""
    end
  end
end
