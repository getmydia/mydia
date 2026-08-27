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

  describe "download_subtitle_result/2" do
    # A relay-shaped result. The file id is base64url, which is what made
    # String.to_integer/1 raise and take the LiveView down with it.
    defp relay_result do
      %{
        file_id: "L3N1YnRpdGxlLzM0NjczMzAtODM5MDM4OS56aXA",
        language: "en",
        format: "srt",
        subtitle_hash: "relay-hash",
        provider_id: "registry::relay",
        provider_type: :relay,
        provider_name: "Mydia Relay"
      }
    end

    defp search_socket(results) do
      socket(%{
        selected_media_file: %{id: "mf-1"},
        subtitle_search_results: results,
        downloading_subtitle_index: nil
      })
    end

    test "an out of range index flashes rather than raising" do
      {:noreply, socket} =
        SubtitleEvents.download_subtitle_result(
          %{"index" => "7"},
          search_socket([relay_result()])
        )

      assert socket.assigns.downloading_subtitle_index == nil
      assert flash(socket)["error"] =~ "no longer available"
    end

    test "a non-numeric index flashes rather than raising" do
      {:noreply, socket} =
        SubtitleEvents.download_subtitle_result(
          %{"index" => "not-a-number"},
          search_socket([relay_result()])
        )

      assert socket.assigns.downloading_subtitle_index == nil
      assert flash(socket)["error"] =~ "no longer available"
    end

    # Integer.parse/1 accepts a leading minus sign, so a crafted "-1" would
    # otherwise resolve from the end of the list via Enum.at/2 instead of
    # being rejected as out of range.
    test "a negative index flashes rather than resolving from the end of the list" do
      {:noreply, socket} =
        SubtitleEvents.download_subtitle_result(
          %{"index" => "-1"},
          search_socket([relay_result()])
        )

      assert socket.assigns.downloading_subtitle_index == nil
      assert flash(socket)["error"] =~ "no longer available"
    end

    # Integer.parse/1 requires a binary. The rendered button always sends a
    # DOM string, so reaching these needs a hand-crafted channel push, but the
    # handler still must not raise on one.
    test "a nil index flashes rather than raising" do
      {:noreply, socket} =
        SubtitleEvents.download_subtitle_result(
          %{"index" => nil},
          search_socket([relay_result()])
        )

      assert socket.assigns.downloading_subtitle_index == nil
      assert flash(socket)["error"] =~ "no longer available"
    end

    test "an integer index flashes rather than raising" do
      {:noreply, socket} =
        SubtitleEvents.download_subtitle_result(
          %{"index" => 1},
          search_socket([relay_result()])
        )

      assert socket.assigns.downloading_subtitle_index == nil
      assert flash(socket)["error"] =~ "no longer available"
    end

    test "a payload missing the index key flashes rather than raising" do
      {:noreply, socket} =
        SubtitleEvents.download_subtitle_result(%{}, search_socket([relay_result()]))

      assert socket.assigns.downloading_subtitle_index == nil
      assert flash(socket)["error"] =~ "no longer available"
    end
  end

  describe "set_subtitle_offset/2" do
    # The rendered form always serializes offset_ms as a DOM string, but a
    # hand-crafted channel push is not bound by that. Integer.parse/1 requires
    # a binary and raises FunctionClauseError on anything else, so this must
    # never reach it with a non-string value.
    test "a non-binary offset is ignored rather than raising" do
      {:noreply, socket} =
        SubtitleEvents.set_subtitle_offset(
          %{"media-file-id" => "mf-1", "track-ref" => "0", "offset_ms" => 1500},
          socket()
        )

      assert flash(socket) == %{}
    end

    test "a nil offset is ignored rather than raising" do
      {:noreply, socket} =
        SubtitleEvents.set_subtitle_offset(
          %{"media-file-id" => "mf-1", "track-ref" => "0", "offset_ms" => nil},
          socket()
        )

      assert flash(socket) == %{}
    end

    test "a non-numeric string flashes rather than storing anything" do
      {:noreply, socket} =
        SubtitleEvents.set_subtitle_offset(
          %{"media-file-id" => "mf-1", "track-ref" => "0", "offset_ms" => "not-a-number"},
          socket()
        )

      assert flash(socket)["error"] =~ "whole number"
    end
  end

  describe "nudge_subtitle_offset/2" do
    test "a non-binary delta is ignored rather than raising" do
      {:noreply, socket} =
        SubtitleEvents.nudge_subtitle_offset(
          %{"media-file-id" => "mf-1", "track-ref" => "0", "delta" => 100},
          socket()
        )

      assert flash(socket) == %{}
    end

    test "a nil delta is ignored rather than raising" do
      {:noreply, socket} =
        SubtitleEvents.nudge_subtitle_offset(
          %{"media-file-id" => "mf-1", "track-ref" => "0", "delta" => nil},
          socket()
        )

      assert flash(socket) == %{}
    end
  end

  describe "resync_subtitle/2" do
    # No Oban instance is running in this unit-test module (this app skips it
    # entirely under `testing: :manual`/`engine: false`, see config/test.exs),
    # so `Mydia.Subtitles.ResyncEnqueue.enqueue/2` always takes its rescue path
    # here and returns :error. The success flash is exercised end to end in
    # the connected LiveView test instead, which starts its own Oban instance.
    test "flashes an error rather than crashing when the enqueue fails" do
      {:noreply, socket} =
        SubtitleEvents.resync_subtitle(
          %{"media-file-id" => Ecto.UUID.generate(), "track-ref" => "3"},
          socket()
        )

      assert flash(socket)["error"] == "Could not start the re-sync."
    end

    # The rendered button always sends both phx-value-* attributes, but a
    # hand-crafted channel push is not bound by that. Before the fallback
    # clause existed, either of these raised FunctionClauseError and took the
    # LiveView process down.
    test "a payload missing the media-file-id key is ignored rather than raising" do
      {:noreply, socket} = SubtitleEvents.resync_subtitle(%{"track-ref" => "3"}, socket())

      assert flash(socket) == %{}
    end

    test "a payload missing the track-ref key is ignored rather than raising" do
      {:noreply, socket} =
        SubtitleEvents.resync_subtitle(
          %{"media-file-id" => Ecto.UUID.generate()},
          socket()
        )

      assert flash(socket) == %{}
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

      assert socket.assigns.downloading_subtitle_index == nil
    end

    test "a failed download clears the downloading id and humanizes a known reason" do
      {:noreply, socket} =
        SubtitleEvents.handle_download_subtitle_async({:ok, {:error, :not_found}}, socket())

      assert socket.assigns.downloading_subtitle_index == nil
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

      assert socket.assigns.downloading_subtitle_index == nil
      assert flash(socket)["error"] =~ "check the server logs"
      refute flash(socket)["error"] =~ "boom"
    end
  end
end
