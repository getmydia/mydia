defmodule MydiaWeb.AdminSettingsLive.LanguageComponents do
  @moduledoc """
  The Language section of Admin Settings. Values and writes live in
  `MydiaWeb.AdminSettingsLive.LanguageSettings`.
  """
  use MydiaWeb, :html

  alias MydiaWeb.AdminSettingsLive.LanguageSettings

  attr :settings, :map, required: true
  attr :player_enabled?, :boolean, required: true

  def language_section(assigns) do
    ~H"""
    <div id="language-settings" class="space-y-2">
      <h3 class="font-semibold flex items-center gap-2 px-1">
        <.icon name="hero-language" class="w-4 h-4 opacity-60" /> Language
      </h3>

      <.form for={%{}} id="language-settings-form" phx-change="save_language_settings">
        <div class="bg-base-200 rounded-box divide-y divide-base-300">
          <.language_row
            id="language-row-download-audio"
            label="Download audio"
            key="downloads.audio_language"
            source={@settings["downloads.audio_language"].source}
            description="Search and upgrades prefer releases with this audio. Choosing a language prefers that dub and falls back to the original. Each show can override this."
          >
            <.download_audio_control setting={@settings["downloads.audio_language"]} />
          </.language_row>

          <.language_row
            :if={@player_enabled?}
            id="language-row-playback-audio"
            label="Playback audio"
            key="streaming.audio_language"
            source={@settings["streaming.audio_language"].source}
            description="Which audio track plays. Tries Preferred, then Fallback, then the track the file marks as default."
          >
            <.playback_audio_control setting={@settings["streaming.audio_language"]} />
          </.language_row>

          <.language_row
            :if={@player_enabled?}
            id="language-row-default-track"
            label="Use the file's default track"
            key="streaming.prefer_default_audio_track"
            source={@settings["streaming.prefer_default_audio_track"].source}
            description="Ignore the playback languages above and play the track the file marks as default."
          >
            <.default_track_control setting={@settings["streaming.prefer_default_audio_track"]} />
          </.language_row>

          <.language_row
            id="language-row-subtitles"
            label="Subtitle languages"
            key="streaming.subtitle_language"
            source={@settings["streaming.subtitle_language"].source}
            description="Subtitles fetched for your files, and the languages subtitle search starts with."
          >
            <.subtitle_languages_control setting={@settings["streaming.subtitle_language"]} />
          </.language_row>

          <.language_row
            id="language-row-metadata"
            label="Metadata language"
            key="metadata.language"
            source={@settings["metadata.language"].source}
            description={
              "Locale sent to TMDB/TVDB through the metadata relay (ISO 639-1 like \"de\" or " <>
                "BCP 47 like \"de-DE\"). Affects displayed titles, descriptions, and posters."
            }
          >
            <.metadata_language_control setting={@settings["metadata.language"]} />
          </.language_row>
        </div>
      </.form>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :key, :string, required: true
  attr :source, :atom, required: true
  attr :description, :string, required: true
  slot :inner_block, required: true

  defp language_row(assigns) do
    ~H"""
    <div id={@id} class="p-3 sm:p-4">
      <div class="flex flex-col sm:flex-row sm:items-center gap-2 sm:gap-4">
        <div class="flex-1 min-w-0">
          <div class="font-medium flex items-center gap-2 flex-wrap">
            {@label}
            <.config_source_badge source={@source} />
          </div>
          <div class="text-xs opacity-50 font-mono truncate">{@key}</div>
          <div class="text-xs opacity-60 mt-1">{@description}</div>
        </div>
        <div class="sm:ml-auto">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  attr :setting, :map, required: true

  defp download_audio_control(assigns) do
    current = assigns.setting.value
    none = if is_nil(current), do: [{"", "No preference"}], else: []

    assigns =
      assign(
        assigns,
        :options,
        none ++
          [{"original", "Original language"} | LanguageSettings.language_options(current)]
      )

    ~H"""
    <select
      id="language-download-audio"
      name="download_audio_language"
      class="select select-sm select-bordered w-full sm:w-56"
      disabled={@setting.source == :env}
    >
      <option
        :for={{value, label} <- @options}
        value={value}
        selected={value == (@setting.value || "")}
      >
        {label}
      </option>
    </select>
    """
  end

  attr :setting, :map, required: true

  defp playback_audio_control(assigns) do
    languages = assigns.setting.value
    shown = Enum.take(languages, 2)

    assigns =
      assigns
      |> assign(:preferred, Enum.at(shown, 0))
      |> assign(:fallback, Enum.at(shown, 1))
      |> assign(:hidden_count, length(languages) - length(shown))
      |> assign(:options, [
        {"original", "Original language"} | LanguageSettings.language_options(shown)
      ])
      |> assign(:locked?, assigns.setting.source == :env)

    ~H"""
    <div class="flex flex-col gap-1">
      <div class="flex flex-col sm:flex-row gap-2">
        <label class="flex flex-col gap-1">
          <span class="text-xs opacity-60">Preferred</span>
          <select
            id="language-playback-preferred"
            name="playback_audio[preferred]"
            class="select select-sm select-bordered w-full sm:w-44"
            disabled={@locked?}
          >
            <option :if={is_nil(@preferred)} value="" selected>No preference</option>
            <option :for={{value, label} <- @options} value={value} selected={value == @preferred}>
              {label}
            </option>
          </select>
        </label>
        <label class="flex flex-col gap-1">
          <span class="text-xs opacity-60">Fallback</span>
          <select
            id="language-playback-fallback"
            name="playback_audio[fallback]"
            class="select select-sm select-bordered w-full sm:w-44"
            disabled={@locked?}
          >
            <option value="" selected={is_nil(@fallback)}>None</option>
            <option :for={{value, label} <- @options} value={value} selected={value == @fallback}>
              {label}
            </option>
          </select>
        </label>
      </div>
      <p :if={@hidden_count > 0} id="language-playback-truncation" class="text-xs text-warning">
        {@hidden_count} more configured {if @hidden_count == 1, do: "language", else: "languages"}.
        Saving here keeps only these two.
      </p>
    </div>
    """
  end

  attr :setting, :map, required: true

  defp default_track_control(assigns) do
    ~H"""
    <label class="label cursor-pointer gap-2">
      <input
        type="hidden"
        name="prefer_default_audio_track"
        value="false"
        disabled={@setting.source == :env}
      />
      <input
        id="language-prefer-default-track"
        type="checkbox"
        name="prefer_default_audio_track"
        value="true"
        class="toggle toggle-primary toggle-sm"
        checked={@setting.value}
        disabled={@setting.source == :env}
      />
    </label>
    """
  end

  attr :setting, :map, required: true

  # Same chip set as the subtitle search modal: the common languages plus any
  # selected one outside them, with the rest behind a picker. The last selected
  # chip is disabled so the list cannot become empty, and a hidden input still
  # submits it, since a disabled checkbox is never sent.
  defp subtitle_languages_control(assigns) do
    selected = assigns.setting.value
    common = MydiaWeb.Languages.common()
    common_codes = Enum.map(common, &elem(&1, 0))

    chips =
      common ++
        (selected
         |> Enum.reject(&(&1 in common_codes))
         |> Enum.map(&{&1, MydiaWeb.Languages.name(&1)}))

    chip_codes = Enum.map(chips, &elem(&1, 0))

    assigns =
      assigns
      |> assign(:selected, selected)
      |> assign(:chips, chips)
      |> assign(
        :more,
        Enum.reject(MydiaWeb.Languages.all(), fn {code, _} -> code in chip_codes end)
      )
      |> assign(:locked?, assigns.setting.source == :env)

    ~H"""
    <div class="flex flex-wrap items-center gap-2 sm:justify-end">
      <div class="filter" role="group" aria-label="Subtitle languages">
        <%= for {code, label} <- @chips do %>
          <input
            :if={not @locked? and @selected == [code]}
            type="hidden"
            name="subtitle_language[]"
            value={code}
          />
          <input
            id={"language-subtitle-#{code}"}
            class="btn btn-sm"
            type="checkbox"
            name="subtitle_language[]"
            value={code}
            aria-label={label}
            checked={code in @selected}
            disabled={@locked? or @selected == [code]}
          />
        <% end %>
      </div>
      <select
        :if={@more != []}
        id="language-subtitle-add"
        name="subtitle_language_add"
        class="select select-sm select-bordered w-40"
        disabled={@locked?}
      >
        <option value="" selected>More languages</option>
        <option :for={{code, label} <- @more} value={code}>{label}</option>
      </select>
    </div>
    """
  end

  attr :setting, :map, required: true

  defp metadata_language_control(assigns) do
    ~H"""
    <input
      id="language-metadata-language"
      type="text"
      name="metadata_language"
      value={@setting.value}
      placeholder="en-US"
      phx-debounce="blur"
      disabled={@setting.source == :env}
      class="input input-sm input-bordered w-full sm:w-44 font-mono"
    />
    """
  end
end
