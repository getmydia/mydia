defmodule MydiaWeb.TrailerComponents do
  @moduledoc """
  The web UI's trailer player.

  Renders a container the `TrailerPlayer` hook (`assets/js/hooks/trailer_player.mjs`)
  takes over. The hook plays the first video and moves to the next one when
  YouTube refuses it (region-locked, removed, embedding disabled). With two or
  more videos a row of buttons switches by hand, which also covers region
  blocks YouTube shows in-player without reporting an error.

  The container is `phx-update="ignore"`, so the hook owns everything inside
  it. A caller showing a different title must change `id` to get a fresh
  player; reusing an id keeps the old keys.
  """
  use Phoenix.Component
  use Gettext, backend: MydiaWeb.Gettext

  import MydiaWeb.CoreComponents, only: [icon: 1]

  alias Mydia.Metadata.Structs.Video

  attr :id, :string, required: true
  attr :videos, :list, required: true, doc: "`%Video{}` structs, preferred first"
  attr :autoplay, :boolean, default: false

  attr :button_class, :any,
    default: nil,
    doc: "extra classes for the switcher buttons, e.g. a light text color on a dark modal"

  def trailer_player(assigns) do
    assigns = assign(assigns, :videos, Video.youtube_videos(assigns.videos))

    ~H"""
    <div
      :if={@videos != []}
      id={@id}
      phx-hook="TrailerPlayer"
      phx-update="ignore"
      data-keys={Jason.encode!(Enum.map(@videos, & &1.key))}
      data-autoplay={to_string(@autoplay)}
      data-title={gettext("Trailer")}
      class="space-y-2"
    >
      <div class="relative aspect-video overflow-hidden rounded-lg bg-black">
        <div data-role="player" class="h-full w-full"></div>
        <div data-role="unavailable" class="hidden absolute inset-0">
          <div class="flex h-full flex-col items-center justify-center gap-3 p-6 text-center text-white/80">
            <p>{gettext("No trailer is available in your region.")}</p>
            <a
              href={Video.youtube_watch_url(hd(@videos))}
              target="_blank"
              rel="noopener noreferrer"
              class="btn btn-sm btn-ghost text-white"
            >
              <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" />
              {gettext("Open on YouTube")}
            </a>
          </div>
        </div>
      </div>
      <div
        :if={length(@videos) > 1}
        data-role="switcher"
        role="group"
        aria-label={gettext("Trailers")}
        class="flex flex-wrap gap-1 px-2 pb-2"
      >
        <button
          :for={{video, index} <- Enum.with_index(@videos)}
          type="button"
          data-index={index}
          title={video_label(video, index)}
          aria-pressed={to_string(index == 0)}
          class={[
            "btn btn-xs max-w-48",
            if(index == 0, do: "btn-primary", else: "btn-ghost"),
            @button_class
          ]}
        >
          <span class="truncate">{video_label(video, index)}</span>
        </button>
      </div>
    </div>
    """
  end

  defp video_label(%Video{name: name}, _index) when is_binary(name) and name != "", do: name
  defp video_label(_video, index), do: gettext("Trailer %{number}", number: index + 1)
end
