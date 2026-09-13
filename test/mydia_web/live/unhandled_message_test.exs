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
    MydiaWeb.MediaLive.Index,
    MydiaWeb.ActivityLive.Index,
    MydiaWeb.AdminImportListsLive.Index,
    MydiaWeb.AdminLibraryPathsLive.Index,
    MydiaWeb.AdminPluginsLive.Index,
    MydiaWeb.AdminRemoteAccessLive.Index,
    MydiaWeb.AdminSystemLive.Index,
    MydiaWeb.TranscodesLive.Index
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

      for message <- [{:totally_unexpected, :message}, :totally_unexpected] do
        log =
          capture_log(fn ->
            assert {:noreply, ^socket} = module.handle_info(message, socket)
          end)

        assert log =~ "Unhandled message in #{short_name(module)}"
      end
    end
  end

  @scan_events [
    :library_scan_started,
    :library_scan_progress,
    :library_scan_completed,
    :library_scan_failed
  ]

  for event <- @scan_events do
    test "AdminLibraryPathsLive.Index ignores #{event} silently" do
      socket = %Socket{}

      log =
        capture_log(fn ->
          assert {:noreply, ^socket} =
                   MydiaWeb.AdminLibraryPathsLive.Index.handle_info({unquote(event), %{}}, socket)
        end)

      refute log =~ "Unhandled message in AdminLibraryPathsLive.Index"
    end
  end

  test "AdminLibraryPathsLive.Index tracks a started library reorganization" do
    socket = Phoenix.Component.assign(%Socket{}, :reorganizing_library_ids, MapSet.new())

    assert {:noreply, updated_socket} =
             MydiaWeb.AdminLibraryPathsLive.Index.handle_info(
               {:library_reorganize_started, %{library_path_id: "test-library"}},
               socket
             )

    assert updated_socket.assigns.reorganizing_library_ids == MapSet.new(["test-library"])
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

      # Deliberately not `assert log == ""`. `capture_log/1` intercepts the
      # Logger globally rather than per-process, so under `async: true` any
      # unrelated test that happens to log during this window bleeds into the
      # capture and an emptiness assertion fails at random. Asserting the
      # absence of the catch-all's own line tests the property we actually
      # care about: the grab message was matched by a silent clause and never
      # reached the fall-through.
      refute log =~ "Unhandled message in #{short_name(module)}"
    end
  end
end
