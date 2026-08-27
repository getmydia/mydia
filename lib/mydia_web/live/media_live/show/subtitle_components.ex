defmodule MydiaWeb.MediaLive.Show.SubtitleComponents do
  @moduledoc """
  Subtitle track rows for the media detail page.

  Split out of `components.ex` rather than added to it: that file is already
  large, and these rows carry their own form state.
  """
  use MydiaWeb, :html

  attr :track, :map, required: true
  attr :media_file_id, :string, required: true

  def subtitle_track_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-2 py-2 border-b border-base-300 last:border-0">
      <div class="flex items-center gap-2 min-w-0">
        <span class="badge badge-outline badge-sm">{@track.language}</span>
        <span class="text-sm truncate">{@track.title}</span>
        <span class="text-xs opacity-60 uppercase">{@track.format}</span>
        <span class={["badge badge-sm", origin_class(@track.origin)]}>
          {origin_label(@track.origin)}
        </span>
      </div>

      <div class="flex items-center gap-1 shrink-0">
        <form
          id={"subtitle-offset-form-#{@track.track_id}"}
          phx-change="set_subtitle_offset"
          phx-value-media-file-id={@media_file_id}
          phx-value-track-ref={@track.track_id}
          class="join"
        >
          <button
            type="button"
            class="btn btn-xs join-item"
            phx-click="nudge_subtitle_offset"
            phx-value-media-file-id={@media_file_id}
            phx-value-track-ref={@track.track_id}
            phx-value-delta="-100"
            title="Show subtitles 100 ms earlier"
          >
            <.icon name="hero-minus" class="w-3 h-3" />
          </button>

          <input
            type="number"
            name="offset_ms"
            value={@track.offset_ms}
            step="50"
            class="input input-xs input-bordered join-item w-20 text-center"
            aria-label="Subtitle offset in milliseconds"
          />

          <button
            type="button"
            class="btn btn-xs join-item"
            phx-click="nudge_subtitle_offset"
            phx-value-media-file-id={@media_file_id}
            phx-value-track-ref={@track.track_id}
            phx-value-delta="100"
            title="Show subtitles 100 ms later"
          >
            <.icon name="hero-plus" class="w-3 h-3" />
          </button>
        </form>

        <span class="text-xs opacity-50 w-6">ms</span>

        <%= if @track.origin != :embedded do %>
          <button
            type="button"
            class="btn btn-ghost btn-xs text-error"
            phx-click="delete_subtitle"
            phx-value-subtitle-id={@track.track_id}
            data-confirm="Delete this subtitle file?"
            title="Delete subtitle"
          >
            <.icon name="hero-trash" class="w-4 h-4" />
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  defp origin_label(:embedded), do: "Embedded"
  defp origin_label(:provider), do: "Downloaded"
  defp origin_label(:sidecar), do: "Sidecar"
  defp origin_label(:upload), do: "Uploaded"
  # `origin` is a database column value threaded through a plain map, not a
  # changeset-validated struct, by the time it reaches this component. The
  # extractor already normalizes anything it does not recognize to
  # `:provider` (see `Mydia.Subtitles.Extractor.origin_atom/1`), but this
  # clause exists so a row still renders instead of raising if that mapping
  # is ever missed for some path.
  defp origin_label(_other), do: "Unknown"

  defp origin_class(:embedded), do: "badge-ghost"
  defp origin_class(:provider), do: "badge-info"
  defp origin_class(:sidecar), do: "badge-neutral"
  defp origin_class(:upload), do: "badge-success"
  defp origin_class(_other), do: "badge-ghost"
end
