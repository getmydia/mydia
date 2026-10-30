defmodule MydiaWeb.MediaLive.Index.AlphaJumpComponents do
  @moduledoc """
  The library listing's A-Z strip: `#` then A to Z, pinned to the right edge.
  Letters with titles are patch links; the rest are dimmed and inert. The strip
  shows from `sm` up; phones get `alpha_jump_picker/1`, a select in the toolbar.
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
        "hidden sm:flex fixed z-30 right-0.5 lg:right-1 flex-col items-center justify-between",
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

  attr :paths, :map, required: true, doc: "as for alpha_jump_bar"

  attr :version, :integer,
    required: true,
    doc: "bumped after each jump so the select is rebuilt and shows its placeholder again"

  @doc """
  Phones get this picker, in the toolbar, instead of the strip: 26 letters in a
  20px column cannot be tapped reliably and are too small to read.
  """
  def alpha_jump_picker(assigns) do
    assigns = assign(assigns, :letters, LibraryListing.letters())

    ~H"""
    <.form for={%{}} id="alpha-jump-picker" phx-change="jump_letter" class="sm:hidden">
      <div id={"alpha-jump-picker-#{@version}"}>
        <%!-- The version is in the select's own id too: morphdom keeps a focused
             select's value when it patches the same node, so only a fresh node
             shows the placeholder again. --%>
        <select
          id={"alpha-jump-select-#{@version}"}
          name="letter"
          aria-label={gettext("Jump to letter")}
          class="select select-sm select-bordered w-full"
        >
          <option value="">{gettext("Jump to letter")}</option>
          <%= for letter <- @letters, Map.has_key?(@paths, letter) do %>
            <option value={letter}>{String.upcase(letter)}</option>
          <% end %>
        </select>
      </div>
    </.form>
    """
  end

  defp letter_id("#"), do: "alpha-jump-hash"
  defp letter_id(letter), do: "alpha-jump-#{letter}"

  defp letter_label("#"), do: gettext("Titles starting with a number or symbol")
  defp letter_label(letter), do: String.upcase(letter)
end
