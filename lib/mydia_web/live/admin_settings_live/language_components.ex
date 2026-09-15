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
