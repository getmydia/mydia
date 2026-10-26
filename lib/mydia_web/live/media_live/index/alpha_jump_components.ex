defmodule MydiaWeb.MediaLive.Index.AlphaJumpComponents do
  @moduledoc """
  The library listing's A-Z strip: `#` then A to Z, pinned to the right edge.
  Letters with titles are patch links; the rest are dimmed and inert.
  """
  use MydiaWeb, :html

  alias Mydia.Media.LibraryListing

  attr :paths, :map,
    required: true,
    doc: "letter => listing path starting at it, for the letters with titles"

  def alpha_jump_bar(assigns) do
    assigns = assign(assigns, :letters, LibraryListing.letters())

    ~H"""
    <nav
      id="alpha-jump-bar"
      phx-hook="AlphaJumpBar"
      aria-label={gettext("Jump to letter")}
      class={[
        "fixed z-30 right-0.5 lg:right-1 flex flex-col items-center justify-between",
        "top-24 bottom-[calc(6rem+env(safe-area-inset-bottom,0px))]",
        "lg:top-1/2 lg:bottom-auto lg:-translate-y-1/2 lg:justify-center lg:gap-0.5",
        "rounded-full bg-base-100/70 backdrop-blur px-0.5 py-1 touch-none select-none"
      ]}
    >
      <%= for letter <- @letters do %>
        <.link
          :if={Map.has_key?(@paths, letter)}
          id={letter_id(letter)}
          patch={@paths[letter]}
          replace
          draggable="false"
          data-letter={letter}
          aria-label={letter_label(letter)}
          class="w-5 text-center text-[10px] lg:text-xs leading-tight text-base-content/80 hover:text-primary"
        >
          {String.upcase(letter)}
        </.link>
        <span
          :if={not Map.has_key?(@paths, letter)}
          id={letter_id(letter)}
          data-letter={letter}
          aria-disabled="true"
          class="w-5 text-center text-[10px] lg:text-xs leading-tight text-base-content/30"
        >
          {String.upcase(letter)}
        </span>
      <% end %>
    </nav>
    """
  end

  defp letter_id("#"), do: "alpha-jump-hash"
  defp letter_id(letter), do: "alpha-jump-#{letter}"

  defp letter_label("#"), do: gettext("Titles starting with a number or symbol")
  defp letter_label(letter), do: String.upcase(letter)
end
