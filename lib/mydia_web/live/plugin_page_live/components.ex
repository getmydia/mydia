defmodule MydiaWeb.PluginPageLive.Components do
  @moduledoc "Components for plugin pages: the write confirmation modal."
  use MydiaWeb, :html

  alias Mydia.Plugins.PageWrites
  alias Phoenix.LiveView.JS

  attr :title, :string, required: true
  attr :pending, :list, required: true
  attr :choices, :list, required: true

  def confirm_modal(assigns) do
    assigns = assign(assigns, :groups, Enum.group_by(assigns.pending, & &1.surface))

    ~H"""
    <.modal id="plugin-confirm-modal" show on_cancel={JS.push("decide", value: %{choice: "deny"})}>
      <:title>{@title} wants to make changes</:title>
      <div :for={{surface, rows} <- @groups} class="mb-4">
        <p class="text-sm font-medium text-base-content/70">{PageWrites.surface_label(surface)}</p>
        <ul class="mt-1 space-y-1">
          <li :for={row <- rows} class="text-sm flex gap-2">
            <.icon name="hero-arrow-right" class="w-4 h-4 mt-0.5 shrink-0 text-base-content/50" />
            <span>{row.description}</span>
          </li>
        </ul>
      </div>
      <p class="text-xs text-base-content/60">
        Every change is listed under Activity and can be undone there.
      </p>
      <:actions>
        <div class="flex flex-wrap gap-2 justify-end">
          <button
            id="plugin-confirm-deny"
            class="btn btn-ghost"
            phx-click="decide"
            phx-value-choice="deny"
          >
            Deny
          </button>
          <button
            :if={"once" in @choices}
            id="plugin-confirm-once"
            class="btn"
            phx-click="decide"
            phx-value-choice="once"
          >
            Allow once
          </button>
          <button
            :if={"session" in @choices}
            id="plugin-confirm-session"
            class="btn"
            phx-click="decide"
            phx-value-choice="session"
          >
            Allow for this session
          </button>
          <button
            :if={"always" in @choices}
            id="plugin-confirm-always"
            class="btn btn-primary"
            phx-click="decide"
            phx-value-choice="always"
          >
            Always allow
          </button>
        </div>
      </:actions>
    </.modal>
    """
  end

  attr :entry, :map, required: true

  def journal_row(assigns) do
    ~H"""
    <div id={"journal-#{@entry.id}"} class="flex items-center gap-3 text-sm">
      <span class="flex-1">{@entry.description}</span>
      <span
        :if={@entry.status != "applied"}
        class={["badge badge-sm", status_class(@entry.status)]}
      >
        {status_label(@entry.status)}
      </span>
      <button
        :if={@entry.status == "applied"}
        id={"undo-#{@entry.id}"}
        class="btn btn-ghost btn-xs"
        phx-click="undo_entry"
        phx-value-id={@entry.id}
      >
        Undo
      </button>
    </div>
    """
  end

  defp status_label("undone"), do: "Undone"
  defp status_label("conflict"), do: "Changed since"
  defp status_label("irreversible"), do: "Can't undo"

  defp status_class("undone"), do: "badge-ghost"
  defp status_class(_), do: "badge-warning"
end
