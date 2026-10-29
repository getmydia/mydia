defmodule MydiaWeb.MediaLive.Show.DownloadComponents do
  @moduledoc """
  The detail page's download surfaces: the banner that says what is
  downloading, and the per-episode progress ring that replaces an episode's
  status chip while its download runs.
  """

  use MydiaWeb, :html

  import MydiaWeb.MediaLive.Show.Formatters, only: [format_download_status: 1]

  alias MydiaWeb.DownloadsLive.Format
  alias MydiaWeb.MediaLive.Show.DownloadSummary
  alias MydiaWeb.MediaLive.Show.DownloadSummaryItem, as: Item

  # Labels shown before the rest collapse into "+N more".
  @visible_labels 6

  # daisyUI's radial-progress draws only the arc, so a ring at 5% reads as a
  # stray fleck. An inset shadow as wide as the ring's own --thickness, tinted
  # from the ring colour, draws the track under it.
  @ring_track "[box-shadow:inset_0_0_0_var(--thickness)_color-mix(in_oklab,currentColor_20%,transparent)]"

  @doc """
  Names what is downloading for this item, with one ring for overall
  progress and a link to the Downloads page. Renders nothing when no download
  is active.
  """
  attr :media_item, :map, required: true
  attr :summary, DownloadSummary, default: nil

  def active_download_banner(%{summary: nil} = assigns), do: ~H""

  def active_download_banner(assigns) do
    {visible, hidden} = Enum.split(assigns.summary.items, @visible_labels)

    assigns =
      assigns
      |> assign(:visible, visible)
      |> assign(:hidden_count, length(hidden))
      |> assign(:percent, round(assigns.summary.progress))
      |> assign(:ring_track, @ring_track)
      |> assign(:heading, heading(assigns.media_item, assigns.summary))

    ~H"""
    <div
      id="active-download-alert"
      role="status"
      class="alert alert-info alert-soft alert-vertical sm:alert-horizontal mb-6"
    >
      <div
        id="active-download-progress"
        class={["radial-progress shrink-0", @ring_track, ring_color(@summary.state)]}
        style={"--value:#{@percent}; --size:3.25rem; --thickness:0.3rem;"}
        role="progressbar"
        aria-valuenow={@percent}
        aria-valuemin="0"
        aria-valuemax="100"
        aria-label={gettext("Overall download progress")}
      >
        <span class="text-xs font-semibold tabular-nums">{@percent}%</span>
      </div>

      <%!-- alert-vertical centres its children below `sm`; the rows inside
            follow suit so the labels do not hang left under a centred heading. --%>
      <div class="flex-1 min-w-0 w-full space-y-2">
        <div class="flex flex-wrap items-center justify-center sm:justify-start gap-2">
          <h3 id="active-download-heading" class="font-bold">{@heading}</h3>
          <span
            :if={@summary.state}
            id="active-download-state"
            class={["badge badge-sm badge-soft", state_badge(@summary.state)]}
          >
            {format_download_status(@summary.state)}
          </span>
          <span
            :if={@summary.eta}
            id="active-download-eta"
            class="badge badge-sm badge-ghost gap-1 tabular-nums"
          >
            <.icon name="hero-clock" class="size-3" />
            {gettext("%{eta} left", eta: Format.format_eta(@summary.eta))}
          </span>
        </div>

        <%= if @media_item.type == "movie" do %>
          <p :for={item <- @visible} class="text-sm font-mono truncate opacity-80">
            {item.download.title}
          </p>
        <% else %>
          <ul
            id="active-download-items"
            class="flex flex-wrap justify-center sm:justify-start gap-1.5"
          >
            <li :for={item <- @visible} class="tooltip tooltip-bottom" data-tip={item_tooltip(item)}>
              <span class={[
                "badge badge-sm badge-outline badge-info gap-1",
                item.kind != :other && "font-mono tabular-nums",
                item.kind == :other && "max-w-56 truncate"
              ]}>
                <.icon :if={item.kind == :season_pack} name="hero-archive-box" class="size-3" />
                {item_label(item)}
              </span>
            </li>
            <li :if={@hidden_count > 0}>
              <span class="badge badge-sm badge-ghost">
                {gettext("+%{count} more", count: @hidden_count)}
              </span>
            </li>
          </ul>
        <% end %>
      </div>

      <.link
        id="active-download-link"
        navigate={~p"/downloads"}
        class="btn btn-sm btn-ghost gap-1 shrink-0"
      >
        {gettext("View downloads")} <.icon name="hero-arrow-right" class="size-4" />
      </.link>
    </div>
    """
  end

  @doc """
  A ring sized to the episode row's 1.5rem status column, standing in for the
  status chip while a download for that episode is active. The tooltip says
  what the ring cannot: the state, the percentage and the release.
  """
  attr :episode_id, :string, required: true
  attr :download, :map, required: true

  def episode_download_ring(assigns) do
    assigns =
      assigns
      |> assign(:percent, round(assigns.download.progress || 0))
      |> assign(:ring_track, @ring_track)

    ~H"""
    <div
      class="tooltip tooltip-left @md/eprow:justify-self-end"
      data-tip={episode_tooltip(@download, @percent)}
    >
      <div
        id={"episode-#{@episode_id}-download"}
        class={["radial-progress", @ring_track, ring_color(@download.status)]}
        style={"--value:#{@percent}; --size:1.25rem; --thickness:0.2rem;"}
        role="progressbar"
        aria-valuenow={@percent}
        aria-valuemin="0"
        aria-valuemax="100"
      >
        <span class="sr-only">{episode_tooltip(@download, @percent)}</span>
      </div>
    </div>
    """
  end

  defp heading(%{type: "movie"}, _summary), do: gettext("Downloading")

  defp heading(_media_item, %DownloadSummary{by_episode: by_episode, items: items}) do
    case map_size(by_episode) do
      0 ->
        ngettext("%{count} download in progress", "%{count} downloads in progress", length(items))

      count ->
        ngettext("Downloading %{count} episode", "Downloading %{count} episodes", count)
    end
  end

  @doc false
  def item_label(%Item{kind: :episode, season_number: s, episode_number: e})
      when is_integer(s) and is_integer(e),
      do: pgettext("tv", "S%{season}E%{episode}", season: pad(s), episode: pad(e))

  def item_label(%Item{kind: :season_pack, season_number: s}),
    do: gettext("Season %{number}", number: s)

  def item_label(%Item{download: download}), do: download.title

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")

  defp item_tooltip(%Item{download: download}) do
    "#{format_download_status(download.status)} · " <>
      "#{round(download.progress || 0)}% · #{download.title}"
  end

  defp episode_tooltip(download, percent) do
    "#{format_download_status(download.status)} #{percent}% · #{download.title}"
  end

  defp ring_color("paused"), do: "text-warning"
  defp ring_color(_status), do: "text-info"

  defp state_badge("paused"), do: "badge-warning"
  defp state_badge(_status), do: "badge-info"
end
