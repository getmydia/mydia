defmodule MydiaWeb.MediaLive.Show.AudioTracksTest do
  @moduledoc """
  The file rows list every audio track in a file, not just the analyzer's
  first audio stream (#1179). A remux carrying TrueHD plus an AC3
  compatibility track used to read as whichever had been muxed first.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Mydia.Library.MediaFile
  alias Mydia.Library.Structs.FileMetadata
  alias Mydia.Library.Structs.StreamInfo
  alias MydiaWeb.MediaLive.Show.AudioTrackComponents

  defp track(index, codec, attrs) do
    struct!(%StreamInfo{index: index, type: :audio, codec: codec, language: "eng"}, attrs)
  end

  defp file(streams, audio_codec \\ "ac3") do
    %MediaFile{
      id: "mf-1",
      audio_codec: audio_codec,
      metadata: if(streams, do: %FileMetadata{streams: streams})
    }
  end

  defp render_tracks(file, opts \\ []) do
    render_component(&AudioTrackComponents.audio_tracks/1, [file: file, id: "f"] ++ opts)
  end

  defp texts(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()))
  end

  test "lists every audio track, default first and commentary last" do
    streams = [
      %StreamInfo{index: 0, type: :video, codec: "hevc"},
      track(1, "ac3", channels: 6, is_commentary: true),
      track(2, "ac3", channels: 6),
      track(3, "truehd", channels: 8, profile: "Dolby TrueHD + Dolby Atmos", is_default: true)
    ]

    html = render_tracks(file(streams))

    assert texts(html, "[id^='audio-track-f-']") ==
             ["TrueHD Atmos 7.1", "AC3 5.1", "AC3 5.1 commentary"]
  end

  test "treats a track titled as commentary as commentary without the disposition flag" do
    streams = [
      track(1, "ac3", channels: 2, title: "Director's Commentary"),
      track(2, "dts", channels: 6)
    ]

    assert texts(render_tracks(file(streams)), "[id^='audio-track-f-']") ==
             ["DTS 5.1", "AC3 Stereo commentary"]
  end

  test "shows the language only when tracks differ in language" do
    streams = [
      track(1, "eac3", channels: 6, language: "eng", is_default: true),
      track(2, "aac", channels: 2, language: "jpn")
    ]

    assert texts(render_tracks(file(streams)), "[id^='audio-track-f-']") ==
             ["DD+ 5.1 eng", "AAC Stereo jpn"]
  end

  test "falls back to the audio_codec column when no streams were stored" do
    html = render_tracks(file(nil, "eac3"))

    assert texts(html, "#audio-tracks-f") == ["eac3"]
    assert texts(html, "[id^='audio-track-f-']") == []
  end

  test "renders the fallback text, or nothing, when there is no audio data at all" do
    assert texts(render_tracks(file(nil, nil), fallback: "Unknown"), "#audio-tracks-f") ==
             ["Unknown"]

    assert texts(render_tracks(file(nil, nil)), "#audio-tracks-f") == []
  end
end
