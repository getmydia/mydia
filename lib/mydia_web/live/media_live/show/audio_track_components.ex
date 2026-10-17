defmodule MydiaWeb.MediaLive.Show.AudioTrackComponents do
  @moduledoc """
  Audio track labels for the media detail page's file rows.

  Split out of `components.ex` rather than added to it: that file is past the
  module-size ratchet and may only shrink.
  """
  use MydiaWeb, :html

  alias Mydia.Library.Structs.StreamInfo

  @doc """
  Every audio track in a file, one label each ("TrueHD Atmos 7.1 · AC3 5.1").

  The `audio_codec` column holds the analyzer's first audio stream only, so a
  remux carrying TrueHD plus an AC3 compatibility track read as whichever was
  muxed first. This reads `metadata.streams` instead and lists them all, the
  default track first and commentary last. Files analyzed before streams were
  stored fall back to the column.

  The language code is shown only when the tracks span more than one language;
  on a single-language file it would repeat the same "ENG" on every track.
  """
  attr :file, :map, required: true
  attr :id, :string, required: true
  attr :fallback, :string, default: nil
  attr :class, :any, default: nil

  def audio_tracks(assigns) do
    tracks = audio_track_streams(assigns.file)

    show_language? =
      tracks |> Enum.map(& &1.language) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length() > 1

    assigns =
      assign(assigns,
        tracks: tracks,
        show_language?: show_language?,
        column: shorten_codec(assigns.file.audio_codec) || assigns.fallback
      )

    ~H"""
    <span
      :if={@tracks != [] or @column}
      id={"audio-tracks-#{@id}"}
      class={["inline-flex flex-wrap items-center gap-x-1.5 gap-y-0.5", @class]}
    >
      <%= if @tracks == [] do %>
        <span title={@file.audio_codec}>{@column}</span>
      <% else %>
        <%= for {track, i} <- Enum.with_index(@tracks) do %>
          <span :if={i > 0} class="opacity-40" aria-hidden="true">·</span>
          <% commentary? = StreamInfo.commentary?(track) %>
          <span
            id={"audio-track-#{@id}-#{track.index}"}
            class={["inline-flex items-baseline gap-1", commentary? && "opacity-60"]}
            title={audio_track_title(track)}
          >
            <span>{StreamInfo.audio_label(track) || "Unknown"}</span>
            <span :if={@show_language? && track.language} class="uppercase opacity-70">
              {track.language}
            </span>
            <span :if={commentary?} class="italic">commentary</span>
          </span>
        <% end %>
      <% end %>
    </span>
    """
  end

  @doc "Shortens a long codec name for display."
  @spec shorten_codec(String.t() | nil) :: String.t() | nil
  def shorten_codec(nil), do: nil

  def shorten_codec(codec) do
    codec
    |> String.replace(~r/\s*\([^)]*\)/, "")
    |> String.replace("Dolby Digital Plus", "DD+")
    |> String.replace("Dolby Digital", "DD")
    |> String.replace("DTS-HD MA", "DTS-MA")
  end

  defp audio_track_streams(%{metadata: %{streams: streams}}) when is_list(streams) do
    streams
    |> Enum.filter(&(&1.type == :audio))
    |> Enum.with_index()
    |> Enum.sort_by(fn {track, position} -> {audio_track_rank(track), position} end)
    |> Enum.map(&elem(&1, 0))
  end

  defp audio_track_streams(_file), do: []

  defp audio_track_rank(track) do
    cond do
      StreamInfo.commentary?(track) -> 2
      track.is_default -> 0
      true -> 1
    end
  end

  defp audio_track_title(track) do
    [track.codec_long || track.codec, track.channel_layout, track.language, track.title]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end
end
