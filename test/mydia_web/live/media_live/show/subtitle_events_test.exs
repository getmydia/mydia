defmodule MydiaWeb.MediaLive.Show.SubtitleEventsTest do
  use MydiaWeb.ConnCase, async: true

  alias MydiaWeb.MediaLive.Show.SubtitleEvents

  # `flash: %{}` and `private.live_temp` satisfy `Phoenix.LiveView.put_flash/3`,
  # which some of the async handlers still call on their remaining paths.
  defp socket(assigns \\ %{}) do
    base = %{__changed__: %{}, flash: %{}, selected_languages: ["en"]}

    %Phoenix.LiveView.Socket{
      assigns: Map.merge(base, assigns),
      private: %{live_temp: %{}}
    }
  end

  defp flash(%Phoenix.LiveView.Socket{assigns: %{flash: f}}), do: f

  describe "update_subtitle_languages/2" do
    test "stores the submitted selection" do
      {:noreply, socket} =
        SubtitleEvents.update_subtitle_languages(%{"languages" => ["en", "fr"]}, socket())

      assert socket.assigns.selected_languages == ["en", "fr"]
    end

    test "treats a payload with no languages key as an empty selection" do
      # Unchecking every daisyUI chip omits the key entirely rather than
      # sending an empty list, which used to raise FunctionClauseError.
      {:noreply, socket} = SubtitleEvents.update_subtitle_languages(%{}, socket())

      assert socket.assigns.selected_languages == []
    end
  end

  describe "clear_subtitle_languages/2" do
    test "empties the selection" do
      {:noreply, socket} =
        SubtitleEvents.clear_subtitle_languages(%{}, socket(%{selected_languages: ["en", "fr"]}))

      assert socket.assigns.selected_languages == []
    end
  end

  describe "handle_subtitle_search_async/2" do
    test "a successful search transitions to :loaded with its results and providers" do
      {:noreply, socket} =
        SubtitleEvents.handle_subtitle_search_async(
          {:ok, {:ok, %{results: [], providers: []}}},
          socket()
        )

      assert socket.assigns.subtitle_search_state == :loaded
      assert socket.assigns.subtitle_search_results == []
      assert socket.assigns.subtitle_providers == []
    end

    test "a top-level search error carries the reason and sets no flash" do
      {:noreply, socket} =
        SubtitleEvents.handle_subtitle_search_async(
          {:ok, {:error, :media_file_not_found}},
          socket()
        )

      assert socket.assigns.subtitle_search_state == {:error, :media_file_not_found}
      assert flash(socket) == %{}
    end

    test "a crashed search task becomes a reportable :crashed state" do
      {:noreply, socket} =
        SubtitleEvents.handle_subtitle_search_async({:exit, :boom}, socket())

      assert socket.assigns.subtitle_search_state == {:error, :crashed}
    end
  end

  describe "handle_download_subtitle_async/2" do
    defp socket_with_media_item(assigns \\ %{}) do
      socket(Map.merge(%{media_item: %{media_files: []}}, assigns))
    end

    test "a successful download clears the downloading id" do
      {:noreply, socket} =
        SubtitleEvents.handle_download_subtitle_async(
          {:ok, {:ok, %{}}},
          socket_with_media_item()
        )

      assert socket.assigns.downloading_subtitle_id == nil
    end

    test "a failed download clears the downloading id and humanizes a known reason" do
      {:noreply, socket} =
        SubtitleEvents.handle_download_subtitle_async({:ok, {:error, :not_found}}, socket())

      assert socket.assigns.downloading_subtitle_id == nil
      assert flash(socket)["error"] =~ "no longer available from the provider"
      refute flash(socket)["error"] =~ "not_found"
    end

    test "a failed download with an unrecognized reason never flashes the raw term" do
      {:noreply, socket} =
        SubtitleEvents.handle_download_subtitle_async(
          {:ok, {:error, {:database_insert_failed, %{}}}},
          socket()
        )

      assert flash(socket)["error"] =~ "check the server logs"
      refute flash(socket)["error"] =~ "database_insert_failed"
    end

    test "a crashed download task clears the downloading id and never flashes the raw reason" do
      {:noreply, socket} =
        SubtitleEvents.handle_download_subtitle_async({:exit, :boom}, socket())

      assert socket.assigns.downloading_subtitle_id == nil
      assert flash(socket)["error"] =~ "check the server logs"
      refute flash(socket)["error"] =~ "boom"
    end
  end
end
