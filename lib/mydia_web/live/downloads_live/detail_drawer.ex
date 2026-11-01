defmodule MydiaWeb.DownloadsLive.DetailDrawer do
  @moduledoc """
  The detail panel for one download, opened from a row through
  `?download=<id>`. It shows only stored and already-polled data from the
  enriched row, with no extra per-download client calls.

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
  attr :display, Mydia.TimeDisplay, required: true
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
        progress: trunc(download.progress || 0),
        indeterminate: ListView.progress_indeterminate?(download)
      )

    ~H"""
    <dialog
      id="download-detail"
      class="modal modal-end"
      open
      phx-window-keydown="close_details"
      phx-key="Escape"
    >
      <div class="modal-box h-full max-h-none w-full max-w-lg rounded-none">
        <div class="py-4">
          <div class="flex flex-col gap-5 min-h-full">
            <div class="flex items-start gap-4 pr-8">
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
                :if={@tab == :queue and not @indeterminate}
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
              <span>
                {gettext("No progress for %{duration}.",
                  duration: format_duration(ListView.stall_elapsed_seconds(@download))
                )}
              </span>
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
                    do: gettext("Import retrying"),
                    else: gettext("Import failed")}
                </p>
                <pre class="whitespace-pre-wrap break-words text-xs mt-1">{@download.import_last_error}</pre>
              </div>
            </div>

            <.path_mapping_block
              :if={
                @download.import_failed_at &&
                  @download.import_failure_reason == "path_mapping_mismatch"
              }
              download={@download}
            />

            <div
              :if={copied_placement(@download)}
              id="import-placement-warning"
              role="alert"
              class="alert alert-warning alert-soft items-start"
            >
              <.icon name="hero-document-duplicate" class="size-4 mt-0.5" />
              <div class="min-w-0 text-sm">
                <p class="font-medium">{gettext("Copied instead of hardlinked")}</p>
                <p class="mt-1">{placement_advice(copied_placement(@download))}</p>
              </div>
            </div>

            <div
              :if={@download.removal_error}
              id="download-detail-removal-error"
              role="alert"
              class="alert alert-error alert-soft items-start"
            >
              <.icon name="hero-exclamation-triangle" class="size-4 mt-0.5" />
              <pre class="whitespace-pre-wrap break-words text-xs">{gettext("Couldn't remove from %{client}: %{error}", client: @download.download_client, error: @download.removal_error)}</pre>
            </div>

            <fieldset id="download-detail-release" class="fieldset">
              <legend class="fieldset-legend">{pgettext("release", "Release")}</legend>
              <dl class="grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1 text-sm">
                <dt class="text-base-content/60">{gettext("Title")}</dt>
                <dd class="break-all">{@download.title}</dd>
                <.detail_row label={gettext("Quality")} value={@quality} />
                <.detail_row label={gettext("Protocol")} value={@protocol} />
                <.detail_row
                  label={gettext("Size")}
                  value={@download.size && format_file_size(@download.size)}
                />
                <.detail_row label={gettext("Seeders")} value={@seeders} />
              </dl>
            </fieldset>

            <fieldset :if={@download.download_client} id="download-detail-client" class="fieldset">
              <legend class="fieldset-legend">{gettext("Client")}</legend>
              <dl class="grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1 text-sm">
                <.detail_row label={gettext("Name")} value={@download.download_client} />
                <.detail_row label={gettext("Client ID")} value={@download.download_client_id} mono />
                <.detail_row label={gettext("Save path")} value={@download.save_path} mono />
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
                {gettext("Open in %{client}", client: @download.download_client)}
              </a>
            </fieldset>

            <fieldset id="download-detail-timeline" class="fieldset">
              <legend class="fieldset-legend">{gettext("Timeline")}</legend>
              <ul class="timeline timeline-vertical timeline-compact">
                <li
                  :for={{{slug, label, at, icon, color}, index} <- Enum.with_index(@events)}
                  id={"download-detail-event-#{slug}"}
                >
                  <hr :if={index > 0} />
                  <div class="timeline-middle">
                    <.icon name={icon} class={"size-4 #{color}"} />
                  </div>
                  <div class="timeline-end timeline-box text-sm">
                    <span class="font-medium">{label}</span>
                    <span
                      class="tooltip text-base-content/60 ml-1"
                      data-tip={format_absolute_time(at, @display)}
                    >
                      {format_relative_time(at, @display)}
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
              <legend class="fieldset-legend">{pgettext("import", "Import")}</legend>
              <dl class="grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1 text-sm">
                <.detail_row
                  label={gettext("Reported path")}
                  value={@download.import_reported_path}
                  mono
                />
                <.detail_row label={gettext("Failure")} value={@download.import_failure_reason} />
                <.detail_row
                  :if={(@download.import_retry_count || 0) > 0}
                  label={gettext("Attempts")}
                  value={@download.import_retry_count}
                />
                <.detail_row
                  :if={@download.import_next_retry_at}
                  label={gettext("Next retry")}
                  value={format_next_retry(@download.import_next_retry_at)}
                />
              </dl>
            </fieldset>

            <div class="modal-action mt-auto">
              <ListComponents.download_actions download={@download} tab={@tab} context="drawer" />
            </div>
          </div>
        </div>

        <form method="dialog">
          <button
            id="download-detail-close"
            type="button"
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            aria-label={gettext("Close")}
            phx-click="close_details"
          >
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
        </form>
      </div>

      <form method="dialog" class="modal-backdrop">
        <button type="button" id="download-detail-backdrop" phx-click="close_details">
          {gettext("close")}
        </button>
      </form>
    </dialog>
    """
  end

  # Why a path-mapping failure happened and how to fix it: the suggested
  # mapping with a one-click apply when one was found, a link to the Path
  # Mappings page otherwise. `path_mapping_suggestion` is stored on the
  # download when the import fails and arrives via the history builders; the
  # Index only sets `path_mapping_affected_count`.
  attr :download, :map, required: true

  defp path_mapping_block(assigns) do
    ~H"""
    <div
      id="drawer-path-mapping"
      role="note"
      class="alert alert-warning alert-soft items-start text-sm"
    >
      <.icon name="hero-folder-open" class="size-4 mt-0.5" />
      <div class="min-w-0">
        <p>
          {gettext(
            "Mydia can't see the download client's path. This usually means its volume isn't mounted into the Mydia container at the same path."
          )}
        </p>
        <%= if @download.path_mapping_suggestion do %>
          <p class="mt-2 font-mono text-xs break-all">
            {@download.path_mapping_suggestion.remote_prefix}
            <span class="opacity-50">→</span>
            {@download.path_mapping_suggestion.local_prefix}
          </p>
          <div class="mt-2 flex flex-wrap items-center gap-2">
            <button
              type="button"
              id={"drawer-apply-mapping-#{@download.id}"}
              class="btn btn-warning btn-xs"
              phx-click="apply_mapping_and_retry"
              phx-value-remote_prefix={@download.path_mapping_suggestion.remote_prefix}
              phx-value-local_prefix={@download.path_mapping_suggestion.local_prefix}
              phx-disable-with={gettext("Applying…")}
              aria-label={
                gettext("Apply mapping %{remote} to %{local} and retry",
                  remote: @download.path_mapping_suggestion.remote_prefix,
                  local: @download.path_mapping_suggestion.local_prefix
                )
              }
            >
              {gettext("Apply mapping & retry")}
            </button>
            <span :if={@download.path_mapping_affected_count} class="text-xs opacity-70">
              {ngettext(
                "Retries %{count} download",
                "Retries %{count} downloads",
                @download.path_mapping_affected_count
              )}
            </span>
          </div>
        <% else %>
          <.link
            id={"drawer-path-mappings-link-#{@download.id}"}
            navigate={~p"/admin/path-mappings"}
            class="link link-warning mt-2 inline-block"
          >
            {gettext("Add a path mapping")}
          </.link>
        <% end %>
      </div>
    </div>
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

  defp copied_placement(%{metadata: %{"import_placement" => %{"method" => "copy"} = p}}), do: p
  defp copied_placement(_download), do: nil

  defp placement_advice(%{"reason" => "link_refused"}),
    do:
      gettext(
        "The download and library folders are on the same disk but reached through different mounts. Map one parent folder (for example /data) that holds both, and point the download client at the same path."
      )

  defp placement_advice(_),
    do:
      gettext(
        "The download and library folders are on different filesystems, so hardlinks are not possible."
      )

  # Only the events this download has reached, oldest first.
  defp timeline_events(download) do
    [
      {"grabbed", gettext("Grabbed"), download.inserted_at, "hero-arrow-down-tray",
       "text-base-content/60"},
      {"last-progress", gettext("Last progress"), download.last_progress_at,
       "hero-arrow-trending-up", "text-base-content/60"},
      {"stalled", gettext("Stalled since"), download.stalled_since, "hero-clock", "text-warning"},
      {"completed", pgettext("download", "Completed"),
       download.completed_at || download.db_completed_at, "hero-check", "text-success"},
      {"imported", pgettext("download", "Imported"), download.imported_at, "hero-check-circle",
       "text-success"}
    ]
    |> Enum.filter(fn {_slug, _label, at, _icon, _color} -> match?(%DateTime{}, at) end)
  end
end
