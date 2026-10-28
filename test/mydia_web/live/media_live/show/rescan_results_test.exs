defmodule MydiaWeb.MediaLive.Show.RescanResultsTest do
  use MydiaWeb.ConnCase, async: true

  alias MydiaWeb.MediaLive.Show.RescanResults

  @message "None of this item's folders were found on disk. Run a library scan to find files that were moved or renamed."

  defp socket do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, flash: %{}, rescanning_season: 1},
      private: %{live_temp: %{}}
    }
  end

  defp error_flash(%Phoenix.LiveView.Socket{assigns: %{flash: f}}), do: f["error"]

  test "series rescan reports :no_files_on_disk" do
    {:noreply, socket} =
      RescanResults.handle_rescan_series_async(
        {:ok, {{:error, :no_files_on_disk}, {:ok, 0, []}}},
        socket()
      )

    assert error_flash(socket) == @message
  end

  test "movie rescan reports :no_files_on_disk" do
    {:noreply, socket} =
      RescanResults.handle_rescan_movie_async(
        {:ok, {{:error, :no_files_on_disk}, {:ok, 0, []}}},
        socket()
      )

    assert error_flash(socket) == @message
  end

  test "season rescan reports :no_files_on_disk and clears the spinner" do
    {:noreply, socket} =
      RescanResults.handle_rescan_season_async(
        {:ok, {1, {:error, :no_files_on_disk}, {:ok, 0, []}}},
        socket()
      )

    assert error_flash(socket) == @message
    assert socket.assigns.rescanning_season == nil
  end
end
