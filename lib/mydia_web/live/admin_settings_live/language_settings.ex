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
  Writes the setting(s) a form change actually changed.

  `params` is the Language form's change payload. A browser reports which
  field fired the change as `params["_target"]`, and serializes the whole
  form alongside it, debounced fields included, so only that field is parsed;
  otherwise changing one field could write another field's uncommitted,
  in-flight text. When `_target` is absent (a direct `render_hook` or
  `render_change` call with no browser event behind it), every present field
  is parsed, as before.

  A key is written only when it is not locked by an environment variable and
  differs from its resolved value: a write that only repeats the value on
  screen would pin a YAML or default value into the database layer. All the
  writes from one call happen inside a single transaction: a value that
  fails to parse, or a write that fails, rolls back everything else this
  call would have written rather than leaving a partial save. Returns the
  keys written, empty when nothing changed.
  """
  @spec save(map(), binary() | nil) :: {:ok, [String.t()]} | {:error, String.t(), term()}
  def save(params, user_id) do
    settings = current()

    changes =
      params
      |> submitted_fields()
      |> Enum.flat_map(fn field -> parse({field, Map.get(params, field)}, params) end)
      |> Enum.reject(fn {key, value} ->
        settings[key].source == :env or settings[key].value == value
      end)

    fn ->
      Enum.reduce(changes, [], fn
        {key, :invalid}, _written ->
          Mydia.Repo.rollback({key, :invalid})

        {key, value}, written ->
          attrs = %{
            key: key,
            value: encode(value),
            category: category(key),
            updated_by_id: user_id
          }

          case Settings.upsert_config_setting(attrs) do
            {:ok, _setting} -> [key | written]
            {:error, reason} -> Mydia.Repo.rollback({key, reason})
          end
      end)
    end
    |> Mydia.Repo.transaction()
    |> case do
      {:ok, written} -> {:ok, written}
      {:error, {key, reason}} -> {:error, key, reason}
    end
  end

  # The field(s) a form change actually names. `_target`, when the browser
  # supplies it, is the changed field's name path (e.g. `["playback_audio",
  # "preferred"]` for a nested input named `playback_audio[preferred]`); its
  # first segment is the field this change is about, and every other field in
  # `params` is that same form's current (possibly uncommitted) state, not
  # this change. Without `_target`, every present field is used, matching the
  # behaviour before per-field targeting existed.
  defp submitted_fields(%{"_target" => [field | _]}) when is_binary(field), do: [field]
  defp submitted_fields(params), do: params |> Map.delete("_target") |> Map.keys()

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
