defmodule MydiaWeb.MediaLive.Show.SubtitleManageModalTest do
  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Mydia.Library.MediaFile
  alias Mydia.Settings.LibraryPath
  alias MydiaWeb.MediaLive.Show.SubtitleModal

  defp file do
    %MediaFile{
      id: "mf-1",
      path: nil,
      relative_path: "The Bear/S02E03.mkv",
      library_path: %LibraryPath{path: "/media/tv"}
    }
  end

  defp track(opts) do
    %{
      track_id: Keyword.get(opts, :track_id, 1),
      language: Keyword.get(opts, :language, "en"),
      title: "English",
      format: "srt",
      embedded: Keyword.get(opts, :embedded, false),
      origin: Keyword.get(opts, :origin, :provider),
      deliverable: true,
      offset_ms: Keyword.get(opts, :offset_ms, 0),
      resync_state: Keyword.get(opts, :resync_state)
    }
  end

  defp modal(tracks, can_edit \\ true) do
    render_component(&SubtitleModal.subtitle_manage_modal/1,
      media_file: file(),
      tracks: tracks,
      can_edit: can_edit
    )
  end

  describe "for a role that cannot update media" do
    test "lists the tracks with no controls or actions" do
      html = modal([track(track_id: "sub-uuid", offset_ms: 250)], false)

      assert html =~ "English"
      assert html =~ ~s|id="subtitle-offset-mf-1-sub-uuid"|
      refute html =~ "subtitle-offset-form-"
      refute html =~ ~s|phx-click="delete_subtitle"|
      refute html =~ ~s|phx-click="resync_subtitle"|
      refute html =~ ~s|id="subtitle-manage-actions"|
    end

    test "omits the offset note for a track with no correction" do
      refute modal([track(track_id: 1)], false) =~ "subtitle-offset-mf-1-1"
    end
  end

  test "names the file it is managing" do
    assert modal([]) =~ "S02E03.mkv"
  end

  test "renders a row per track with its offset control" do
    html = modal([track(track_id: 1), track(track_id: 2, language: "es")])

    assert html =~ ~s|id="subtitle-offset-form-mf-1-1"|
    assert html =~ ~s|id="subtitle-offset-form-mf-1-2"|
  end

  test "says so when the file has no tracks, without hiding the actions" do
    html = modal([])

    assert html =~ "No subtitle tracks"
    refute html =~ "subtitle-offset-form-mf-1"
  end

  test "offers delete for an external track and not for an embedded one" do
    external = modal([track(track_id: "sub-uuid", origin: :provider)])
    embedded = modal([track(track_id: 3, origin: :embedded)])

    assert external =~ ~s|phx-value-subtitle-id="sub-uuid"|
    refute embedded =~ ~s|phx-click="delete_subtitle"|
  end

  describe "actions" do
    test "offers search, upload and rescan for a file with tracks" do
      html = modal([track(track_id: 1)])

      assert html =~ ~s|id="subtitle-manage-search"|
      assert html =~ ~s|id="subtitle-manage-upload"|
      assert html =~ ~s|id="subtitle-manage-rescan"|
    end

    test "offers all three for a file with no tracks" do
      html = modal([])

      assert html =~ ~s|id="subtitle-manage-search"|
      assert html =~ ~s|id="subtitle-manage-upload"|
      assert html =~ ~s|id="subtitle-manage-rescan"|
    end

    test "each action carries the media file id" do
      html = modal([])
      document = LazyHTML.from_fragment(html)

      for id <- ~w(subtitle-manage-search subtitle-manage-upload subtitle-manage-rescan) do
        [button] = LazyHTML.query(document, "##{id}") |> Enum.to_list()
        assert LazyHTML.attribute(button, "phx-value-media-file-id") == ["mf-1"]
      end
    end
  end
end
