defmodule MydiaWeb.FlashComponents do
  @moduledoc """
  Flash toasts.

  A flash clears itself after `dismiss_after` milliseconds through the
  `FlashAutoDismiss` hook (`assets/js/hooks/flash_auto_dismiss.mjs`), which
  runs the toast's own `phx-click` so the server forgets the flash exactly as
  it does on a manual close. Positioning belongs to `MydiaWeb.Layouts.flash_group/1`,
  the single container every flash renders into.
  """
  use Phoenix.Component
  use Gettext, backend: MydiaWeb.Gettext

  import MydiaWeb.CoreComponents, only: [icon: 1, hide: 2]

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"

  attr :dismiss_after, :any,
    doc: "milliseconds before the flash clears itself, or nil to stay until closed"

  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns =
      assigns
      |> assign_new(:id, fn -> "flash-#{assigns.kind}" end)
      |> assign_new(:dismiss_after, fn -> default_dismiss_after(assigns.kind) end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      phx-hook={@dismiss_after && "FlashAutoDismiss"}
      data-dismiss-after={@dismiss_after}
      role="alert"
      class="pointer-events-auto"
      {@rest}
    >
      <div class={[
        "alert w-80 sm:w-96 max-w-80 sm:max-w-96 text-wrap",
        @kind == :info && "alert-info",
        @kind == :error && "alert-error"
      ]}>
        <.icon :if={@kind == :info} name="hero-information-circle" class="size-5 shrink-0" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0" />
        <div>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <div class="flex-1" />
        <button type="button" class="group self-start cursor-pointer" aria-label={gettext("close")}>
          <.icon name="hero-x-mark" class="size-5 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
    </div>
    """
  end

  # Errors stay longer: they tend to be longer and are the ones worth reading.
  defp default_dismiss_after(:error), do: 10_000
  defp default_dismiss_after(_kind), do: 5_000
end
