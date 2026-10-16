defmodule MydiaWeb.DownloadsLive.DetailDrawer do
  @moduledoc """
  The detail panel for one download, opened from a row through
  `?download=<id>`. It shows only what the enriched row already carries, so it
  opens with no client call.

  `download_url` is never rendered: it carries indexer API keys and tracker
  passkeys.
  """
  use MydiaWeb, :html

  import MydiaWeb.DownloadsLive.Format
  import MydiaWeb.Formatters, only: [format_file_size: 1]

  alias Mydia.Library.Structs.Quality
  alias MydiaWeb.DownloadsLive.{ListComponents, ListView}

  attr :download, :map, required: true
  attr :tab, :atom, required: true
  attr :client_url, :string, default: nil

  def detail_drawer(assigns) do
    download = assigns.download
    {badge_class, status_label} = ListView.status_badge(download)

    assigns =
      assign(assigns,
        media_item_id: ListView.media_item_id(download),
        title: ListView.display_title(download),
        badge_class: badge_class,
        status_label: status_label,
        events: timeline_events(download),
        quality: Quality.format(ListView.get_metadata_value(download, "quality")),
        protocol: format_protocol(ListView.get_metadata_value(download, "download_protocol")),
        seeders: ListView.get_metadata_value(download, "seeders"),
        progress: trunc(download.progress || 0)
      )

    ~H"""
    <.modal
      id="download-detail"
      show
      placement="end"
      box_class="h-full max-h-none w-full max-w-lg rounded-none flex flex-col gap-5"
      on_cancel="close_details"
      phx-window-keydown="close_details"
      phx-key="Escape"
    >
      <div class="flex items-start gap-4">
        <div class="min-w-0 flex-1">
          <.link
            :if={@media_item_id}
            navigate={~p"/media/#{@media_item_id}"}
            class="link link-hover text-lg font-semibold"
          >
            {@title}
          </.link>
          <h3 :if={is_nil(@media_item_id)} class="text-lg font-semibold">{@title}</h3>
          <div class="mt-1 flex flex-wrap items-center gap-2">
            <span class={["badge badge-sm", @badge_class]}>{@status_label}</span>
            <span :if={@download.indexer} class="badge badge-ghost badge-sm">
              {@download.indexer}
            </span>
          </div>
        </div>
        <div
          :if={@tab == :queue}
          class="radial-progress text-primary text-xs shrink-0"
          style={"--value:#{@progress}; --size:3.5rem;"}
          role="progressbar"
          aria-valuenow={@progress}
        >
          {@progress}%
        </div>
      </div>

      <div
        :if={ListView.soft_stalled?(@download)}
        role="alert"
        class="alert alert-warning alert-soft text-sm"
      >
        <.icon name="hero-clock" class="size-4" />
        <span>No progress for {format_duration(ListView.stall_elapsed_seconds(@download))}.</span>
      </div>

      <div
        :if={@download.import_last_error}
        id="download-detail-import-error"
        role="alert"
        class="alert alert-error alert-soft items-start"
      >
        <.icon name="hero-exclamation-triangle" class="size-4 mt-0.5" />
        <div class="min-w-0">
          <p class="font-medium text-sm">
            {if ListView.import_issue(@download) == :retrying,
              do: "Import retrying",
              else: "Import failed"}
          </p>
          <pre class="whitespace-pre-wrap break-words text-xs mt-1">{@download.import_last_error}</pre>
        </div>
      </div>

      <div
        :if={@download.removal_error}
        id="download-detail-removal-error"
        role="alert"
        class="alert alert-error alert-soft items-start"
      >
        <.icon name="hero-exclamation-triangle" class="size-4 mt-0.5" />
        <pre class="whitespace-pre-wrap break-words text-xs">Couldn't remove from {@download.download_client}: {@download.removal_error}</pre>
      </div>

      <fieldset id="download-detail-release" class="fieldset">
        <legend class="fieldset-legend">Release</legend>
        <dl class="grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1 text-sm">
          <dt class="text-base-content/60">Title</dt>
          <dd class="break-all">{@download.title}</dd>
          <.detail_row label="Quality" value={@quality} />
          <.detail_row label="Protocol" value={@protocol} />
          <.detail_row label="Size" value={@download.size && format_file_size(@download.size)} />
          <.detail_row label="Seeders" value={@seeders} />
        </dl>
      </fieldset>

      <fieldset :if={@download.download_client} id="download-detail-client" class="fieldset">
        <legend class="fieldset-legend">Client</legend>
        <dl class="grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1 text-sm">
          <.detail_row label="Name" value={@download.download_client} />
          <.detail_row label="Client ID" value={@download.download_client_id} mono />
          <.detail_row label="Save path" value={@download.save_path} mono />
        </dl>
        <a
          :if={@client_url}
          id="download-detail-open-client"
          href={@client_url}
          target="_blank"
          rel="noopener noreferrer"
          class="btn btn-outline btn-sm mt-2 w-fit"
        >
          <.icon name="hero-arrow-top-right-on-square" class="size-4" />
          Open in {@download.download_client}
        </a>
      </fieldset>

      <fieldset id="download-detail-timeline" class="fieldset">
        <legend class="fieldset-legend">Timeline</legend>
        <ul class="timeline timeline-vertical timeline-compact">
          <li :for={{{label, at, icon, color}, index} <- Enum.with_index(@events)}>
            <hr :if={index > 0} />
            <div class="timeline-middle">
              <.icon name={icon} class={"size-4 #{color}"} />
            </div>
            <div class="timeline-end timeline-box text-sm">
              <span class="font-medium">{label}</span>
              <span class="tooltip text-base-content/60 ml-1" data-tip={format_absolute_time(at)}>
                {format_relative_time(at)}
              </span>
            </div>
            <hr :if={index < length(@events) - 1} />
          </li>
        </ul>
      </fieldset>

      <fieldset
        :if={
          @download.import_reported_path || (@download.import_retry_count || 0) > 0 ||
            @download.import_next_retry_at
        }
        id="download-detail-import"
        class="fieldset"
      >
        <legend class="fieldset-legend">Import</legend>
        <dl class="grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1 text-sm">
          <.detail_row label="Reported path" value={@download.import_reported_path} mono />
          <.detail_row label="Failure" value={@download.import_failure_reason} />
          <.detail_row
            :if={(@download.import_retry_count || 0) > 0}
            label="Attempts"
            value={@download.import_retry_count}
          />
          <.detail_row
            :if={@download.import_next_retry_at}
            label="Next retry"
            value={format_next_retry(@download.import_next_retry_at)}
          />
        </dl>
      </fieldset>

      <div class="modal-action mt-auto">
        <ListComponents.download_actions download={@download} tab={@tab} context="drawer" />
      </div>
    </.modal>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :mono, :boolean, default: false

  defp detail_row(assigns) do
    ~H"""
    <%= if @value not in [nil, "", false] do %>
      <dt class="text-base-content/60">{@label}</dt>
      <dd class={["break-all", @mono && "font-mono text-xs"]}>{@value}</dd>
    <% end %>
    """
  end

  # Only the events this download has reached, oldest first.
  defp timeline_events(download) do
    [
      {"Grabbed", download.inserted_at, "hero-arrow-down-tray", "text-base-content/60"},
      {"Last progress", download.last_progress_at, "hero-arrow-trending-up",
       "text-base-content/60"},
      {"Stalled since", download.stalled_since, "hero-clock", "text-warning"},
      {"Completed", download.completed_at || download.db_completed_at, "hero-check",
       "text-success"},
      {"Imported", download.imported_at, "hero-check-circle", "text-success"}
    ]
    |> Enum.filter(fn {_label, at, _icon, _color} -> match?(%DateTime{}, at) end)
  end
end
