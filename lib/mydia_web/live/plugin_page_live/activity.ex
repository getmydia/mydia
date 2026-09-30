defmodule MydiaWeb.PluginPageLive.Activity do
  @moduledoc """
  The signed-in user's journaled writes for one plugin, with undo.

  Undo only ever acts as this LiveView's user on entries listed here. An entry
  that changed since, or that cannot be reversed, is reported and left as is.
  """
  use MydiaWeb, :live_view

  alias Mydia.Plugins.Journal
  alias MydiaWeb.PluginPageLive.Components

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Activity")
     |> assign(:slug, slug)
     |> load()}
  end

  @impl true
  def handle_event("undo_entry", %{"id" => id}, socket) when is_binary(id) do
    flash =
      if listed?(socket, id) do
        undo_flash(Journal.undo_entry(socket.assigns.current_user, id))
      else
        {:error, "That change is no longer listed."}
      end

    {:noreply, socket |> put_undo_flash(flash) |> load()}
  end

  def handle_event("undo_batch", %{"batch" => batch}, socket) when is_binary(batch) do
    %{current_user: user, slug: slug} = socket.assigns
    {:ok, entries} = Journal.undo_batch(user, slug, batch)

    flash =
      if Enum.all?(entries, &(&1.status == "undone")),
        do: {:info, "Undone."},
        else: {:error, "Some changes could not be undone, and were left as they are."}

    {:noreply, socket |> put_undo_flash(flash) |> load()}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp listed?(socket, id),
    do: socket.assigns.batches |> List.flatten() |> Enum.any?(&(&1.id == id))

  defp undo_flash({:ok, _}), do: {:info, "Undone."}

  defp undo_flash({:error, :conflict}),
    do: {:error, "That changed since, so it was left as it is."}

  defp undo_flash({:error, :irreversible}),
    do: {:error, "That change can no longer be undone."}

  defp undo_flash({:error, :already_undone}), do: {:info, "That was already undone."}
  defp undo_flash({:error, _}), do: {:error, "Could not undo that change."}

  defp put_undo_flash(socket, {kind, message}), do: put_flash(socket, kind, message)

  defp load(socket) do
    entries = Journal.list(socket.assigns.slug, socket.assigns.current_user.id)
    assign(socket, :batches, group_batches(entries))
  end

  # Entries arrive newest first. Group by batch while keeping that order, since
  # one batch's entries are not always adjacent when two requests interleave.
  defp group_batches(entries) do
    entries
    |> Enum.group_by(& &1.batch_id)
    |> Map.values()
    |> Enum.sort_by(fn [first | _] -> first.inserted_at end, {:desc, DateTime})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {assigns}>
      <div class="max-w-2xl space-y-4">
        <.link navigate={~p"/plugins/#{@slug}"} id="activity-back" class="btn btn-ghost btn-sm">
          <.icon name="hero-arrow-left" class="w-4 h-4" /> Back
        </.link>
        <h1 class="text-xl font-semibold">Activity</h1>
        <p :if={@batches == []} id="journal-empty" class="text-base-content/60">Nothing yet.</p>
        <div
          :for={batch <- @batches}
          id={"batch-#{hd(batch).batch_id}"}
          class="card bg-base-100 border border-base-300"
        >
          <div class="card-body p-4 gap-2">
            <div class="flex items-center justify-between">
              <span class="text-xs text-base-content/60">
                {Calendar.strftime(hd(batch).inserted_at, "%Y-%m-%d %H:%M")}
              </span>
              <button
                :if={length(batch) > 1 and Enum.any?(batch, &(&1.status == "applied"))}
                id={"undo-batch-#{hd(batch).batch_id}"}
                class="btn btn-ghost btn-xs"
                phx-click="undo_batch"
                phx-value-batch={hd(batch).batch_id}
              >
                Undo all
              </button>
            </div>
            <Components.journal_row :for={entry <- batch} entry={entry} />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
