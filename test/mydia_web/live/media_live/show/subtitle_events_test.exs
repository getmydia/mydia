defmodule MydiaWeb.MediaLive.Show.SubtitleEventsTest do
  use MydiaWeb.ConnCase, async: true

  import Mydia.MediaFixtures

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
      socket(
        Map.merge(
          %{
            media_item: %{media_files: []},
            selected_media_file: %{id: "mf-1"},
            return_to_manage: false
          },
          assigns
        )
      )
    end

    test "a successful download clears the downloading id" do
      {:noreply, socket} =
        SubtitleEvents.handle_download_subtitle_async(
          {:ok, {:ok, %{}}},
          socket_with_media_item()
        )

      assert socket.assigns.downloading_subtitle_index == nil
    end

    test "a successful download started from the manage modal reopens it and refreshes manage_tracks" do
      {:noreply, socket} =
        SubtitleEvents.handle_download_subtitle_async(
          {:ok, {:ok, %{}}},
          socket_with_media_item(%{return_to_manage: true})
        )

      assert socket.assigns.show_subtitle_manage_modal == true
      assert socket.assigns.show_subtitle_search_modal == false
      assert socket.assigns.selected_media_file == %{id: "mf-1"}
      assert socket.assigns.manage_tracks == []
    end

    test "a successful download not started from the manage modal drops back to the page" do
      {:noreply, socket} =
        SubtitleEvents.handle_download_subtitle_async(
          {:ok, {:ok, %{}}},
          socket_with_media_item(%{return_to_manage: false})
        )

      assert socket.assigns.show_subtitle_manage_modal == false
      assert socket.assigns.selected_media_file == nil
    end

    # Reproduces the sequence a real user can trigger: open search from the
    # manage modal, start a download, close search (which reopens manage),
    # then close the manage modal itself (which nils selected_media_file and
    # resets return_to_manage) before the pending download resolves. The
    # handler must not dereference a nil selected_media_file.
    test "a download resolving after the manage modal was already closed does not crash" do
      {:noreply, socket} =
        SubtitleEvents.handle_download_subtitle_async(
          {:ok, {:ok, %{}}},
          socket_with_media_item(%{
            selected_media_file: nil,
            return_to_manage: false,
            show_subtitle_manage_modal: false
          })
        )

      assert socket.assigns.selected_media_file == nil
      assert socket.assigns.show_subtitle_manage_modal == false
      assert socket.assigns.media_file_subtitle_tracks == %{}
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

  describe "handle_rescan_subtitles_async/2" do
    # A real media_item + media_file (no directory needed:
    # Extractor.list_subtitle_tracks/1 falls back to [] for embedded tracks
    # when the file doesn't exist on disk) with one subtitle row inserted
    # directly, standing in for what Sidecars.reconcile/1 would have just
    # adopted. media_files is set by hand rather than preloaded, since this
    # bypasses the real mount entirely.
    defp movie_with_subtitle_row(hash) do
      media_item = media_item_fixture(%{type: "movie"})
      media_file = media_file_fixture(%{media_item_id: media_item.id})

      {:ok, subtitle} =
        %Mydia.Subtitles.Subtitle{}
        |> Mydia.Subtitles.Subtitle.changeset(%{
          media_file_id: media_file.id,
          language: "en",
          provider: "sidecar",
          origin: "sidecar",
          subtitle_hash: hash,
          file_path: "/tmp/#{hash}.srt",
          format: "srt"
        })
        |> Mydia.Repo.insert()

      {%{media_item | media_files: [media_file]}, media_file, subtitle}
    end

    test "refreshes manage_tracks for the file open in the manage modal" do
      {media_item, media_file, subtitle} = movie_with_subtitle_row("rescan-refresh-hash")

      {:noreply, socket} =
        SubtitleEvents.handle_rescan_subtitles_async(
          {:ok, {:ok, %{adopted: 1, reaped: 0}}},
          socket(%{media_item: media_item, selected_media_file: media_file})
        )

      assert [track] = socket.assigns.manage_tracks
      assert to_string(track.track_id) == subtitle.id

      assert socket.assigns.media_file_subtitle_tracks[media_file.id] ==
               socket.assigns.manage_tracks
    end

    test "updates media_file_subtitle_tracks without touching manage_tracks when nothing is selected" do
      {media_item, _media_file, _subtitle} = movie_with_subtitle_row("rescan-no-selection-hash")

      {:noreply, socket} =
        SubtitleEvents.handle_rescan_subtitles_async(
          {:ok, {:ok, %{adopted: 1, reaped: 0}}},
          socket(%{media_item: media_item, selected_media_file: nil})
        )

      refute Map.has_key?(socket.assigns, :manage_tracks)
      assert map_size(socket.assigns.media_file_subtitle_tracks) == 1
    end
  end

  describe "finish_upload/6" do
    @srt """
    1
    00:00:01,000 --> 00:00:02,000
    Hello.
    """

    # Mirrors subtitle_upload_test.exs's movie_with_media_file/2: a real
    # directory and stand-in file on disk, since
    # Mydia.Subtitles.upload_subtitle/3 (via Uploader) resolves a real
    # destination path from media_file.library_path. This does not need a
    # connected LiveView at all: finish_upload/6 receives already-consumed
    # upload bytes, so this test is invoking the exact same function body
    # that a real upload runs, just without the file_input/render_upload
    # dance that produces those bytes in the first place.
    defp movie_with_real_media_file(relative_path) do
      dir = Path.join(System.tmp_dir!(), "finish-upload-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      library_path = Mydia.SettingsFixtures.library_path_fixture(%{path: dir})
      media_item = media_item_fixture(%{type: "movie"})

      media_file =
        %{
          media_item_id: media_item.id,
          library_path_id: library_path.id,
          relative_path: relative_path
        }
        |> media_file_fixture()
        |> Mydia.Repo.preload(:library_path)

      File.write!(Path.join(dir, relative_path), "not really a video")

      {%{media_item | media_files: [media_file]}, media_file}
    end

    test "a successful upload started from the manage modal reopens it with the new track" do
      {media_item, media_file} = movie_with_real_media_file("Finish-Upload-Manage.mkv")

      {:noreply, socket} =
        SubtitleEvents.finish_upload(
          socket(%{
            media_item: media_item,
            selected_media_file: media_file,
            return_to_manage: true
          }),
          media_file,
          @srt,
          "en",
          false,
          false
        )

      assert socket.assigns.show_subtitle_upload_modal == false
      assert socket.assigns.show_subtitle_manage_modal == true
      assert socket.assigns.selected_media_file == media_file
      assert [track] = socket.assigns.manage_tracks
      assert track.origin == :upload

      assert [subtitle] = Mydia.Subtitles.list_subtitles(media_file.id)
      on_exit(fn -> File.rm(subtitle.file_path) end)
    end

    test "a successful upload not started from the manage modal does not reopen it" do
      {media_item, media_file} = movie_with_real_media_file("Finish-Upload-Direct.mkv")

      {:noreply, socket} =
        SubtitleEvents.finish_upload(
          socket(%{
            media_item: media_item,
            selected_media_file: media_file,
            return_to_manage: false
          }),
          media_file,
          @srt,
          "en",
          false,
          false
        )

      assert socket.assigns.show_subtitle_manage_modal == false
      assert socket.assigns.selected_media_file == nil
      refute Map.has_key?(socket.assigns, :manage_tracks)

      assert [subtitle] = Mydia.Subtitles.list_subtitles(media_file.id)
      on_exit(fn -> File.rm(subtitle.file_path) end)
    end
  end
end
