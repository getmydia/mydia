defmodule MydiaWeb.MediaLive.Show.SubtitleComponents do
  @moduledoc """
  Subtitle track rows for the media detail page.

  Split out of `components.ex` rather than added to it: that file is already
  large, and these rows carry their own form state.
  """
  use MydiaWeb, :html

  # The resync outcomes that mean the auto-sync did not produce a usable result.
  # `ok` and `already_synced` are successes; `nil` means it was never attempted.
  # Anything unrecognised is treated as not-declined, so a future state string
  # cannot make every badge light up before the UI knows how to phrase it.
  @declined_resync_states ~w(low_confidence implausible no_audio too_few_cues no_cues failed)

  @max_visible_codes 3

  @doc """
  The language codes for one media file's subtitle tracks, for a file row.

  Renders nothing when the file has no tracks: a repeated "none" line down a
  170-episode season is noise, and the row's subtitle button stays present
  regardless, so an empty file is still actionable.

  Origin is deliberately not encoded here. Whether a track is embedded, sidecar,
  downloaded, or uploaded is visible in the manage modal, where it is
  actionable; on the row it would compete with the sync marker for the same
  small surface.
  """
  attr :tracks, :list, required: true
  attr :id, :string, required: true

  def subtitle_badges(assigns) do
    codes = summarize_codes(assigns.tracks)

    assigns =
      assigns
      |> assign(:visible_codes, Enum.take(codes, @max_visible_codes))
      |> assign(:overflow_count, max(length(codes) - @max_visible_codes, 0))

    ~H"""
    <div
      :if={@visible_codes != []}
      id={"subtitle-badges-#{@id}"}
      class="flex flex-wrap items-center gap-1"
    >
      <.icon name="hero-language" class="w-3.5 h-3.5 opacity-50 shrink-0" />
      <span
        :for={code <- @visible_codes}
        data-subtitle-code={code.language}
        data-subtitle-sync={code.declined_reason && "declined"}
        title={code.declined_reason}
        class={[
          "badge badge-xs",
          if(code.declined_reason, do: "badge-warning", else: "badge-outline")
        ]}
      >
        {String.upcase(code.language)}
      </span>
      <span :if={@overflow_count > 0} class="badge badge-xs badge-ghost">
        +{@overflow_count}
      </span>
    </div>
    """
  end

  # One entry per distinct language, in first-seen order, carrying the reason
  # text when any track in that language declined to sync.
  defp summarize_codes(tracks) do
    tracks
    |> Enum.reduce({[], MapSet.new()}, fn track, {acc, seen} ->
      language = track.language || "und"

      if MapSet.member?(seen, language) do
        {merge_declined(acc, language, track), seen}
      else
        entry = %{language: language, declined_reason: declined_reason(track)}
        {acc ++ [entry], MapSet.put(seen, language)}
      end
    end)
    |> elem(0)
  end

  defp merge_declined(acc, language, track) do
    case declined_reason(track) do
      nil ->
        acc

      reason ->
        Enum.map(acc, fn
          %{language: ^language, declined_reason: nil} = entry ->
            %{entry | declined_reason: reason}

          entry ->
            entry
        end)
    end
  end

  defp declined_reason(%{resync_state: state}) when is_binary(state) do
    if state in @declined_resync_states, do: resync_label(state), else: nil
  end

  defp declined_reason(_track), do: nil

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
          id={"subtitle-offset-form-#{@media_file_id}-#{@track.track_id}"}
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

        <button
          id={"resync-subtitle-#{@media_file_id}-#{@track.track_id}"}
          type="button"
          class="btn btn-ghost btn-xs"
          phx-click="resync_subtitle"
          phx-value-media-file-id={@media_file_id}
          phx-value-track-ref={@track.track_id}
          title="Auto-sync this subtitle to the audio"
        >
          <.icon name="hero-arrow-path" class="w-3 h-3" /> Auto-sync
        </button>

        <% resync_message = resync_label(@track[:resync_state]) %>
        <span
          :if={resync_message}
          id={"resync-state-#{@media_file_id}-#{@track.track_id}"}
          class="text-xs opacity-70"
        >
          {resync_message}
        </span>

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

  # A declined outcome says so plainly rather than leaving the button looking
  # like it silently did nothing. `too_few_cues` in particular is expected for
  # forced or foreign-only tracks, where the manual stepper is the right tool.
  # The catch-all clause covers `nil` (never attempted) and any future state
  # this UI does not yet know how to phrase; either way, nothing renders.
  defp resync_label("ok"), do: "Synced automatically"
  defp resync_label("already_synced"), do: "Already in sync"
  defp resync_label("low_confidence"), do: "Could not match the audio confidently"
  defp resync_label("implausible"), do: "Result was out of range"
  defp resync_label("no_audio"), do: "No readable audio track"
  defp resync_label("too_few_cues"), do: "Too few subtitle lines to match reliably"
  defp resync_label("no_cues"), do: "No readable subtitle timings"
  defp resync_label("failed"), do: "Re-sync failed"
  defp resync_label(_other), do: nil
end
