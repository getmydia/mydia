defmodule MydiaWeb.AdminDuplicatesLive.MisfiledComponent do
  @moduledoc """
  The Misfiled section of the duplicates page.

  Needs Attention only sees files that collide with another file on the same
  episode or movie. A file imported under the wrong title into a slot that was
  empty collides with nothing, so it never shows up there (#957). This section
  runs `Mydia.Library.Misfile.scan/0` over the whole library on request. The
  scan parses every file, so it never runs on render.

  Selection works like Needs Attention: suspects start on Review, the
  operator's choices are stored as overrides, and `:returning` is derived.
  The exception is an item where no file binds at all. Nothing there says which
  file is right, so its files start on Leave. `Misfile.send_to_review/2`
  re-verifies every id and refuses to empty an item, so this component is not
  the safety boundary.

  After a send it tells the parent LiveView, which reports the result with the
  same flash and toast as its own sends and reloads the duplicates plan.
  """

  use MydiaWeb, :live_component

  alias Mydia.Library.Misfile
  alias MydiaWeb.AdminDuplicatesLive.{Components, ReviewComponents}

  require Logger

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(findings: nil, overrides: %{}, scanning?: false, scan_failed?: false)
     |> assign_returning()}
  end

  @impl true
  def handle_event("scan", _params, socket) do
    {:noreply,
     socket
     |> assign(scanning?: true, scan_failed?: false)
     |> start_async(:scan, fn -> Misfile.scan() end)}
  end

  def handle_event("leave_file", %{"subject" => item_id, "file" => file_id}, socket) do
    {:noreply, put_override(socket, item_id, file_id, :leave)}
  end

  def handle_event("review_file", %{"subject" => item_id, "file" => file_id}, socket) do
    {:noreply, put_override(socket, item_id, file_id, :review)}
  end

  def handle_event("send_item", %{"item" => item_id}, socket) do
    ids =
      for finding <- socket.assigns.findings || [],
          finding.media_item.id == item_id,
          {file, _reason} <- finding.suspects,
          MapSet.member?(socket.assigns.returning, file.id),
          do: file.id

    {:noreply, send_files(socket, ids)}
  end

  def handle_event("send_all", _params, socket) do
    {:noreply, send_files(socket, MapSet.to_list(socket.assigns.returning))}
  end

  @impl true
  def handle_async(:scan, {:ok, findings}, socket) do
    {:noreply,
     socket
     |> assign(scanning?: false, findings: findings, overrides: %{})
     |> assign_returning()}
  end

  def handle_async(:scan, {:exit, reason}, socket) do
    Logger.error("Misfiled scan failed", reason: inspect(reason))
    {:noreply, assign(socket, scanning?: false, scan_failed?: true)}
  end

  defp send_files(socket, []), do: socket

  defp send_files(socket, ids) do
    actor_id = to_string(socket.assigns.current_scope.user.id)
    result = Misfile.send_to_review(ids, actor_id)
    send(self(), {:misfiled_sent, result})

    sent = MapSet.new(result.returned, & &1.id)

    socket
    |> assign(:findings, drop_sent(socket.assigns.findings, sent))
    |> assign_returning()
  end

  defp drop_sent(findings, sent) do
    Enum.flat_map(findings, fn finding ->
      case Enum.reject(finding.suspects, fn {file, _} -> MapSet.member?(sent, file.id) end) do
        [] ->
          []

        left ->
          gone = length(finding.suspects) - length(left)
          [%{finding | suspects: left, file_count: finding.file_count - gone}]
      end
    end)
  end

  defp assign_returning(socket) do
    %{findings: findings, overrides: overrides} = socket.assigns

    returning =
      for finding <- findings || [],
          {file, _reason} <- finding.suspects,
          review?(file, finding, overrides),
          into: MapSet.new(),
          do: file.id

    assign(socket, :returning, returning)
  end

  defp review?(file, finding, overrides) do
    case Map.fetch(overrides, file.id) do
      {:ok, disposition} -> disposition == :review
      :error -> not finding.nothing_binds?
    end
  end

  # An override only moves for a suspect of the item the event names, and never
  # onto Review for the item's last remaining file. That radio is disabled, so
  # reaching the refusal here means a forged event.
  defp put_override(socket, item_id, file_id, disposition) do
    finding = find_finding(socket, item_id)

    cond do
      is_nil(finding) ->
        socket

      not Enum.any?(finding.suspects, fn {file, _} -> file.id == file_id end) ->
        socket

      disposition == :review and last_left?(socket.assigns.returning, finding, file_id) ->
        socket

      true ->
        socket
        |> assign(:overrides, Map.put(socket.assigns.overrides, file_id, disposition))
        |> assign_returning()
    end
  end

  defp find_finding(socket, item_id),
    do: Enum.find(socket.assigns.findings || [], &(&1.media_item.id == item_id))

  # True when sending `file_id` as well would leave the item with no file.
  defp last_left?(returning, finding, file_id) do
    others =
      Enum.count(finding.suspects, fn {file, _} ->
        file.id != file_id and MapSet.member?(returning, file.id)
      end)

    finding.file_count - others <= 1
  end

  defp item_returning(returning, finding),
    do: Enum.count(finding.suspects, fn {file, _} -> MapSet.member?(returning, file.id) end)

  defp reason_label(:wrong_episode), do: "Wrong episode"
  defp reason_label(:unbound), do: "Doesn't match"

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="space-y-3">
      <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3 pt-2">
        <h2 class="text-lg font-semibold flex items-center gap-2">
          <.icon name="hero-document-magnifying-glass" class="w-5 h-5 opacity-60" /> Misfiled
          <span :if={@findings} class="badge badge-ghost">{length(@findings)}</span>
        </h2>
        <div class="flex items-center gap-2">
          <button
            id="misfiled-scan"
            type="button"
            class="btn btn-sm"
            phx-click="scan"
            phx-target={@myself}
            disabled={@scanning?}
          >
            <span :if={@scanning?} class="loading loading-spinner loading-xs"></span>
            <.icon :if={!@scanning?} name="hero-arrow-path" class="w-4 h-4" />
            {if @findings, do: "Scan again", else: "Scan for misfiled files"}
          </button>
          <button
            :if={@findings not in [nil, []]}
            id="misfiled-send-all"
            type="button"
            class="btn btn-sm btn-primary"
            disabled={MapSet.size(@returning) == 0}
            phx-click="send_all"
            phx-target={@myself}
            phx-disable-with="Sending..."
            data-confirm={"Send #{Components.file_count(MapSet.size(@returning))} to Review? They stay on disk and wait in Review until someone matches them."}
          >
            <.icon name="hero-arrow-uturn-left" class="w-4 h-4" />
            Send {Components.file_count(MapSet.size(@returning))} to Review
          </button>
        </div>
      </div>

      <p class="text-sm text-base-content/60">
        Files attached to an item while their own name and folder point to a different
        title or episode. They don't collide with another file, so Needs Attention can't
        see them. Scanning reads every file in the library and can take a while.
      </p>

      <div :if={@scan_failed?} id="misfiled-error" class="alert alert-error text-sm">
        The scan failed. Check the server logs, then try again.
      </div>

      <%= cond do %>
        <% is_nil(@findings) -> %>
        <% @findings == [] -> %>
          <div id="misfiled-empty" class="bg-base-200 rounded-box p-4 text-sm text-base-content/70">
            <.icon name="hero-check-circle" class="w-5 h-5 text-success inline" />
            No misfiled files found.
          </div>
        <% true -> %>
          <div class="bg-base-200 rounded-box divide-y divide-base-300">
            <div
              :for={finding <- @findings}
              id={"misfiled-item-#{finding.media_item.id}"}
              class="p-3 sm:p-4"
            >
              <div class="flex items-center gap-3">
                <div class="flex-1 min-w-0">
                  <div class="font-medium truncate">{finding.media_item.title}</div>
                  <div class="text-xs opacity-60 truncate">
                    {Components.file_count(length(finding.suspects))} of {finding.file_count} flagged
                  </div>
                </div>
                <span
                  :if={finding.nothing_binds?}
                  class="badge badge-sm badge-outline badge-warning"
                >
                  Nothing matches
                </span>
                <button
                  id={"misfiled-send-item-#{finding.media_item.id}"}
                  type="button"
                  class="btn btn-sm"
                  disabled={item_returning(@returning, finding) == 0}
                  phx-click="send_item"
                  phx-value-item={finding.media_item.id}
                  phx-target={@myself}
                  phx-disable-with="Sending..."
                >
                  <.icon name="hero-arrow-uturn-left" class="w-4 h-4" />
                  Send {Components.file_count(item_returning(@returning, finding))} to Review
                </button>
              </div>

              <p :if={finding.nothing_binds?} class="text-sm text-base-content/60 mt-2">
                None of this item's files match its title, so nothing says which one is right.
                Check the item's match before sending anything.
              </p>

              <div class="bg-base-100 rounded-box divide-y divide-base-300 mt-3">
                <ReviewComponents.review_file_row
                  :for={{file, reason} <- finding.suspects}
                  file={file}
                  subject_id={finding.media_item.id}
                  suspect?={true}
                  suspect_label={reason_label(reason)}
                  returning?={MapSet.member?(@returning, file.id)}
                  last_left?={
                    not MapSet.member?(@returning, file.id) and
                      last_left?(@returning, finding, file.id)
                  }
                  id_prefix="misfiled"
                  target={@myself}
                />
              </div>
            </div>
          </div>
      <% end %>
    </div>
    """
  end
end
