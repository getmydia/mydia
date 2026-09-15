defmodule MydiaWeb.MediaLive.Show.AudioLanguageComponents do
  @moduledoc """
  The hero column's Audio language row and its page-level modal.

  A modal rather than an anchored dropdown for the reason documented on
  `MydiaWeb.MediaLive.Show.LibraryComponents.target_library_row/1`: the hero
  column is `overflow-y-auto`, which clips an anchored `.dropdown-content`.

  The list set here decides which releases automatic and manual search prefer
  for this show; see `Mydia.Media.AudioLanguagePolicy`.
  """
  use MydiaWeb, :html

  alias Mydia.Media.AudioLanguagePolicy

  @slots 0..2

  attr :media_item, :map, required: true

  def audio_language_row(assigns) do
    assigns = assign(assigns, :summary, summary(assigns.media_item))

    ~H"""
    <button
      id="audio-language-row"
      type="button"
      phx-click="show_audio_language_modal"
      class="flex items-center gap-2.5 px-2 py-1.5 rounded-lg cursor-pointer hover:bg-base-300/50 transition-colors w-full group"
      title="Click to change the preferred audio language"
    >
      <div class="w-8 h-8 rounded-lg bg-info/10 flex items-center justify-center flex-shrink-0">
        <.icon name="hero-language" class="w-4 h-4 text-info" />
      </div>
      <div class="flex-1 min-w-0 text-left">
        <div class="text-xs text-base-content/50">Audio Language</div>
        <div class="text-sm font-medium truncate">{@summary}</div>
      </div>
      <.icon
        name="hero-chevron-right"
        class="w-4 h-4 text-base-content/30 group-hover:text-base-content/60 transition-colors flex-shrink-0"
      />
    </button>
    """
  end

  attr :media_item, :map, required: true

  def audio_language_modal(assigns) do
    current = assigns.media_item.audio_languages || []

    assigns =
      assigns
      |> assign(:slots, Enum.map(@slots, &{&1, Enum.at(current, &1)}))
      |> assign(:options, options())
      |> assign(:server_summary, server_summary())

    ~H"""
    <div id="audio-language-modal" class="modal modal-open">
      <div class="modal-box max-w-sm">
        <h3 class="font-bold text-lg mb-1">Audio Language</h3>
        <p class="text-sm text-base-content/60 mb-4">
          Releases carrying the first language win, then the next. Dual audio
          satisfies more than one.
        </p>

        <.form for={%{}} as={:audio} id="audio-language-form" phx-submit="save_audio_languages">
          <.input
            :for={{slot, value} <- @slots}
            id={"audio-language-slot-#{slot}"}
            type="select"
            name={"audio_languages[#{slot}]"}
            label={"Choice #{slot + 1}"}
            options={@options}
            value={value}
            prompt="None"
          />
          <div class="modal-action">
            <button type="button" phx-click="hide_audio_language_modal" class="btn btn-ghost">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary">Save</button>
          </div>
        </.form>

        <div class="divider text-xs">or</div>
        <button
          id="audio-language-reset"
          type="button"
          phx-click="reset_audio_languages"
          class="btn btn-outline btn-sm w-full"
        >
          Use server default ({@server_summary})
        </button>
      </div>
      <div class="modal-backdrop" phx-click="hide_audio_language_modal"></div>
    </div>
    """
  end

  defp summary(%{audio_languages: [_ | _] = languages}), do: names(languages)
  defp summary(_media_item), do: "Server default (#{server_summary()})"

  defp server_summary do
    case AudioLanguagePolicy.server_languages() do
      [] -> "no preference"
      languages -> names(languages)
    end
  end

  defp names(languages), do: Enum.map_join(languages, ", ", &name/1)

  defp name("original"), do: "Original"
  defp name(code), do: MydiaWeb.Languages.name(code)

  defp options do
    [
      {"Original language", "original"}
      | Enum.map(MydiaWeb.Languages.all(), fn {code, label} -> {label, code} end)
    ]
  end
end
