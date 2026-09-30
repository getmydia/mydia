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
end
