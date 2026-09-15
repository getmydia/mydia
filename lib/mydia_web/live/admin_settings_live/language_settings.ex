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

  # An ISO 639-1 (2-letter) or 639-2 (3-letter) primary subtag, optionally
  # followed by BCP 47 subtags: "de", "en-US", "pt-BR", "zh-Hant-TW".
  @language_tag ~r/\A[A-Za-z]{2,3}(-[A-Za-z0-9]{1,8})*\z/

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
      |> Enum.map(fn {key, value} -> {key, keep_order(key, settings[key].value, value)} end)
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
  defp submitted_fields(%{"_target" => [field | _]}) when is_binary(field),
    do: [field_for_target(field)]

  defp submitted_fields(params), do: params |> Map.delete("_target") |> Map.keys()

  # The "More languages" picker is a separate form field from the chip
  # checkboxes it feeds, so a change fired from it targets
  # "subtitle_language_add" while the value it should parse lives under
  # "subtitle_language". Route it there; every other target names its own
  # field already.
  defp field_for_target("subtitle_language_add"), do: "subtitle_language"
  defp field_for_target(field), do: field

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

  # The length bound mirrors metadata_changeset/2, but the tag-shape check
  # (@language_tag) is enforced here, on write, and deliberately not added to
  # Mydia.Config.Schema: a stricter schema check would refuse to boot an
  # install whose existing YAML, env, or database value was accepted before
  # this validation existed.
  defp parse({"metadata_language", tag}, _params) when is_binary(tag) do
    tag = String.trim(tag)

    if String.length(tag) in 2..16 and Regex.match?(@language_tag, tag),
      do: [{"metadata.language", tag}],
      else: [{"metadata.language", :invalid}]
  end

  defp parse({"playback_audio", %{"preferred" => preferred} = pair}, _params)
       when is_binary(preferred) and preferred != "" do
    fallback = Map.get(pair, "fallback", "")
    languages = if fallback in ["", preferred], do: [preferred], else: [preferred, fallback]

    if Enum.all?(languages, &audio_choice?/1),
      do: [{"streaming.audio_language", languages}],
      else: [{"streaming.audio_language", :invalid}]
  end

  defp parse({"prefer_default_audio_track", flag}, _params) when flag in ["true", "false"],
    do: [{"streaming.prefer_default_audio_track", flag == "true"}]

  defp parse({"subtitle_language", codes}, params) when is_list(codes) do
    languages =
      (codes ++ List.wrap(params["subtitle_language_add"]))
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    cond do
      languages == [] -> []
      Enum.all?(languages, &LanguageCode.known?/1) -> [{"streaming.subtitle_language", languages}]
      true -> [{"streaming.subtitle_language", :invalid}]
    end
  end

  defp parse(_field, _params), do: []

  defp audio_choice?(code), do: code == "original" or LanguageCode.known?(code)

  # Chips submit in display order, not preference order. Keep the configured
  # order for languages that stay and append new ones, so an unrelated change
  # on the form never rewrites a YAML or default list just by reordering it.
  defp keep_order("streaming.subtitle_language", current, submitted) when is_list(submitted) do
    Enum.filter(current, &(&1 in submitted)) ++ Enum.reject(submitted, &(&1 in current))
  end

  defp keep_order(_key, _current, value), do: value

  defp encode(list) when is_list(list), do: Enum.join(list, ",")
  defp encode(value), do: to_string(value)

  defp category("downloads." <> _), do: :downloads
  defp category("streaming." <> _), do: :streaming
  defp category("metadata." <> _), do: :metadata
end
