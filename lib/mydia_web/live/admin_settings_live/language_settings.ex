defmodule MydiaWeb.AdminSettingsLive.LanguageSettings do
  @moduledoc """
  What the Language section of Admin Settings shows, and what a change to it
  writes.

  Every language setting is grouped here whichever config section owns its
  key, so download audio, playback audio, subtitles and the metadata language
  sit together. The keys keep their sections, and each row is written with its
  own section as the category.

  Download audio (`downloads.audio_language`) decides which releases search
  prefers. Playback audio (`streaming.audio_language`) decides which track
  plays. They are separate settings on purpose.
  """

  alias Mydia.Metadata.LanguageCode
  alias Mydia.Settings

  @env_vars %{
    "downloads.audio_language" => "DOWNLOAD_AUDIO_LANGUAGE",
    "streaming.audio_language" => "AUDIO_LANGUAGE",
    "streaming.prefer_default_audio_track" => "PREFER_DEFAULT_AUDIO_TRACK",
    "streaming.subtitle_language" => "SUBTITLE_LANGUAGE",
    "metadata.language" => "METADATA_LANGUAGE"
  }

  @type setting :: %{value: term(), source: :env | :database | :default}

  @doc "Each language key's resolved value and the layer it came from."
  @spec current() :: %{String.t() => setting()}
  def current do
    config = Mydia.Config.get()
    db_settings = Settings.applied_config_settings_by_key()

    %{
      "downloads.audio_language" => config.downloads.audio_language,
      "streaming.audio_language" => config.streaming.audio_language || [],
      "streaming.prefer_default_audio_track" => config.streaming.prefer_default_audio_track,
      "streaming.subtitle_language" => config.streaming.subtitle_language || [],
      "metadata.language" => config.metadata.language
    }
    |> Map.new(fn {key, value} ->
      {key, %{value: value, source: Settings.config_source(@env_vars[key], key, db_settings)}}
    end)
  end

  @doc """
  Writes the settings a form change actually changed.

  `params` is the Language form's change payload. A key is written only when it
  is present, is not locked by an environment variable, and differs from its
  resolved value: a write that only repeats the value on screen would pin a
  YAML or default value into the database layer. A value that fails to parse
  stops the save before anything after it is written. Returns the keys written,
  empty when nothing changed.
  """
  @spec save(map(), binary() | nil) :: {:ok, [String.t()]} | {:error, String.t(), term()}
  def save(params, user_id) do
    settings = current()

    params
    |> Enum.flat_map(&parse(&1, params))
    |> Enum.reject(fn {key, value} ->
      settings[key].source == :env or settings[key].value == value
    end)
    |> Enum.reduce_while({:ok, []}, fn
      {key, :invalid}, _acc ->
        {:halt, {:error, key, :invalid}}

      {key, value}, {:ok, written} ->
        attrs = %{key: key, value: encode(value), category: category(key), updated_by_id: user_id}

        case Settings.upsert_config_setting(attrs) do
          {:ok, _setting} -> {:cont, {:ok, [key | written]}}
          {:error, reason} -> {:halt, {:error, key, reason}}
        end
    end)
  end

  @doc """
  The languages a picker offers: `MydiaWeb.Languages.all/0`, plus any current
  value outside that list (set through YAML or an environment variable) so it
  still shows as selected.
  """
  @spec language_options(String.t() | [String.t()] | nil) :: [{String.t(), String.t()}]
  def language_options(current) do
    all = MydiaWeb.Languages.all()

    extra =
      current
      |> List.wrap()
      |> Enum.reject(&(&1 in [nil, "", "original"] or List.keymember?(all, &1, 0)))
      |> Enum.map(&{&1, MydiaWeb.Languages.name(&1)})

    all ++ extra
  end

  defp parse({"download_audio_language", choice}, _params)
       when is_binary(choice) and choice != "" do
    if audio_choice?(choice),
      do: [{"downloads.audio_language", choice}],
      else: [{"downloads.audio_language", :invalid}]
  end

  # The same bounds metadata_changeset/2 enforces, so a value the merged
  # config would reject never reaches the database layer.
  defp parse({"metadata_language", tag}, _params) when is_binary(tag) do
    tag = String.trim(tag)

    if String.length(tag) in 2..16,
      do: [{"metadata.language", tag}],
      else: [{"metadata.language", :invalid}]
  end

  defp parse(_field, _params), do: []

  defp audio_choice?(code), do: code == "original" or LanguageCode.known?(code)

  defp encode(list) when is_list(list), do: Enum.join(list, ",")
  defp encode(value), do: to_string(value)

  defp category("downloads." <> _), do: :downloads
  defp category("streaming." <> _), do: :streaming
  defp category("metadata." <> _), do: :metadata
end
