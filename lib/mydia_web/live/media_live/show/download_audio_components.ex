defmodule MydiaWeb.MediaLive.Show.DownloadAudioComponents do
  @moduledoc """
  The hero column's Download Audio row and its page-level modal.

  A modal rather than an anchored dropdown for the reason documented on
  `MydiaWeb.MediaLive.Show.LibraryComponents.target_library_row/1`: the hero
  column is `overflow-y-auto`, which clips an anchored `.dropdown-content`.

  The choice made here decides which releases automatic and manual search
  prefer for this show; see `Mydia.Media.AudioLanguagePolicy`. It does not
  change which track plays.
  """
  use MydiaWeb, :html

  alias Mydia.Media.AudioLanguagePolicy
  alias Mydia.Metadata.LanguageCode

  attr :media_item, :map, required: true

  def download_audio_row(assigns) do
    assigns = assign(assigns, :summary, summary(assigns.media_item))

    ~H"""
    <button
      id="download-audio-row"
      type="button"
      phx-click="show_download_audio_modal"
      class="flex items-center gap-2.5 px-2 py-1.5 rounded-lg cursor-pointer hover:bg-base-300/50 transition-colors w-full group"
      title="Click to change which audio search prefers"
    >
      <div class="w-8 h-8 rounded-lg bg-info/10 flex items-center justify-center flex-shrink-0">
        <.icon name="hero-language" class="w-4 h-4 text-info" />
      </div>
      <div class="flex-1 min-w-0 text-left">
        <div class="text-xs text-base-content/50">Download Audio</div>
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

  def download_audio_modal(assigns) do
    original = original_language(assigns.media_item)
    current = assigns.media_item.download_audio_language

    assigns =
      assigns
      |> assign(:current, current)
      |> assign(:original, original)
      |> assign(
        :original_active?,
        current == "original" or (original != nil and current == original)
      )
      |> assign(:server_label, choice_label(AudioLanguagePolicy.server_language(), nil))
      |> assign(:languages, language_options(current, original))

    ~H"""
    <div id="download-audio-modal" class="modal modal-open">
      <div class="modal-box max-w-sm">
        <h3 class="font-bold text-lg mb-1">Download Audio</h3>
        <p class="text-sm text-base-content/60 mb-3">
          Search prefers releases with this audio. A language other than the
          original falls back to the original.
        </p>
        <ul class="menu w-full p-0">
          <.option id="download-audio-option-default" value="default" active?={is_nil(@current)}>
            Server default ({@server_label})
          </.option>
          <.option id="download-audio-option-original" value="original" active?={@original_active?}>
            {original_label(@original)}
          </.option>
        </ul>
        <p :if={is_nil(@original)} class="text-xs text-base-content/60 px-3 mt-1">
          This show's original language is unknown, so Original prefers nothing
          until its metadata names one.
        </p>
        <div class="divider my-1"></div>
        <ul class="menu w-full p-0 max-h-64 overflow-y-auto flex-nowrap">
          <.option
            :for={{code, name} <- @languages}
            id={"download-audio-option-#{code}"}
            value={code}
            active?={@current == code and not @original_active?}
          >
            {name}
          </.option>
        </ul>
        <div class="modal-action">
          <button type="button" phx-click="hide_download_audio_modal" class="btn btn-ghost">
            Cancel
          </button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="hide_download_audio_modal"></div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :value, :string, required: true
  attr :active?, :boolean, default: false
  slot :inner_block, required: true

  defp option(assigns) do
    ~H"""
    <li>
      <button
        id={@id}
        type="button"
        phx-click="set_download_audio_language"
        phx-value-language={@value}
        class={["justify-between", @active? && "active"]}
      >
        <span>{render_slot(@inner_block)}</span>
        <.icon :if={@active?} name="hero-check" class="w-4 h-4" />
      </button>
    </li>
    """
  end

  defp summary(%{download_audio_language: choice} = media_item) when is_binary(choice),
    do: choice_label(choice, original_language(media_item))

  defp summary(_media_item),
    do: "Server default (#{choice_label(AudioLanguagePolicy.server_language(), nil)})"

  defp choice_label(nil, _original), do: "no preference"
  defp choice_label("original", nil), do: "Original"
  defp choice_label("original", original), do: "Original (#{MydiaWeb.Languages.name(original)})"
  defp choice_label(code, _original), do: MydiaWeb.Languages.name(code)

  defp original_label(nil), do: "Original language"
  defp original_label(code), do: "Original language (#{MydiaWeb.Languages.name(code)})"

  defp original_language(media_item) do
    media_item.metadata
    |> LanguageCode.original_language_from()
    |> LanguageCode.canonical()
  end

  # Every offered language except the show's own, which the Original row
  # already covers, plus a stored choice outside the offered list so it still
  # shows as active.
  defp language_options(current, original) do
    all = MydiaWeb.Languages.all()

    extra =
      if current in [nil, "original", original] or List.keymember?(all, current, 0),
        do: [],
        else: [{current, MydiaWeb.Languages.name(current)}]

    Enum.reject(all ++ extra, fn {code, _name} -> code == original end)
  end
end
