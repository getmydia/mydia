defmodule Mydia.Indexers.ReleaseLanguages do
  @moduledoc """
  Reads which audio languages a release title claims to carry.

  Titles are the only signal available before a download, so this is a best
  guess from scene and fansub conventions, driven by the vocabulary in
  `priv/release_languages/tokens.exs`:

    * subtitle markers (`Multi-Subs`, `VOSTFR`, `ESub`) are stripped first,
      because they name subtitles and would otherwise trip audio tokens;
    * each audio token contributes its languages (`Dual Audio` is the original
      plus English, `iTALiAN` is Italian);
    * a bracketed combo such as `[ES+JA]` contributes each code that
      `Mydia.Metadata.LanguageCode.known?/1` recognizes, so `[DTS+AAC]` adds
      nothing.

  A title with no audio token is assumed to carry only the original language,
  and says so with `assumed?: true`. Callers use that flag to avoid trading a
  watchable file for a guess.

  Compiled patterns are cached in `:persistent_term`. OTP 28 compiles `:re`
  patterns to references, which cannot be stored in module attributes.
  """

  alias Mydia.Metadata.LanguageCode

  @manifest_path Path.expand("../../../priv/release_languages/tokens.exs", __DIR__)
  @external_resource @manifest_path

  {manifest, _bindings} = Code.eval_file(@manifest_path)

  unless is_map(manifest) and is_list(manifest[:subtitle_markers]) and is_list(manifest[:tokens]) do
    raise CompileError,
      description: "#{@manifest_path} must return %{subtitle_markers: [...], tokens: [...]}"
  end

  @boundary_open "(?<![[:alnum:]])(?:"
  @boundary_close ")(?![[:alnum:]])"

  for source <-
        manifest.subtitle_markers ++ Enum.flat_map(manifest.tokens, &Map.fetch!(&1, :patterns)) do
    case :re.compile(@boundary_open <> source <> @boundary_close, [:caseless, :unicode]) do
      {:ok, _} ->
        :ok

      {:error, {reason, at}} ->
        raise CompileError,
          description: "Bad release language pattern #{inspect(source)}: #{reason} at #{at}"
    end
  end

  @subtitle_sources manifest.subtitle_markers
  @token_sources manifest.tokens
  @combo_source "\\[((?:[a-z]{2,3}\\+)+[a-z]{2,3})\\]"
  @cache_key {__MODULE__, :erlang.phash2({@subtitle_sources, @token_sources, @combo_source})}

  @enforce_keys [:languages, :assumed?]
  defstruct [:languages, :assumed?]

  @type t :: %__MODULE__{languages: [String.t()], assumed?: boolean()}

  @doc """
  Detects the audio languages `title` claims. `original_language` resolves the
  `:original` entries and the assumption for an untagged title.
  """
  @spec detect(String.t() | nil, String.t() | nil) :: t()
  def detect(title, original_language) when is_binary(title) do
    original = LanguageCode.canonical(original_language)

    if String.valid?(title) do
      detect_valid(title, original)
    else
      assumed(original)
    end
  end

  def detect(_title, original_language), do: assumed(LanguageCode.canonical(original_language))

  defp detect_valid(title, original) do
    %{subtitles: subtitles, tokens: tokens, combo: combo} = compiled()

    cleaned =
      Enum.reduce(subtitles, title, fn pattern, acc ->
        :re.replace(acc, pattern, " ", [:global, {:return, :binary}])
      end)

    matched_tokens =
      Enum.filter(tokens, fn %{patterns: patterns} ->
        Enum.any?(patterns, &(:re.run(cleaned, &1, [{:capture, :none}]) == :match))
      end)

    combo_languages = combo_languages(cleaned, combo)

    if matched_tokens == [] and combo_languages == [] do
      assumed(original)
    else
      languages =
        matched_tokens
        |> Enum.flat_map(& &1.languages)
        |> Enum.flat_map(&resolve(&1, original))
        |> Kernel.++(combo_languages)
        |> Enum.uniq()
        |> Enum.sort()

      %__MODULE__{languages: languages, assumed?: false}
    end
  end

  defp combo_languages(title, combo) do
    case :re.run(title, combo, [:global, {:capture, :all_but_first, :binary}]) do
      {:match, groups} ->
        groups
        |> List.flatten()
        |> Enum.flat_map(&String.split(&1, "+"))
        |> Enum.filter(&LanguageCode.known?/1)
        |> Enum.map(&LanguageCode.canonical/1)

      :nomatch ->
        []
    end
  end

  defp resolve(:original, nil), do: []
  defp resolve(:original, original), do: [original]
  defp resolve(code, _original), do: [LanguageCode.canonical(code)]

  defp assumed(nil), do: %__MODULE__{languages: [], assumed?: true}
  defp assumed(original), do: %__MODULE__{languages: [original], assumed?: true}

  defp compiled do
    case :persistent_term.get(@cache_key, nil) do
      nil ->
        compiled = compile_all()
        :persistent_term.put(@cache_key, compiled)
        compiled

      compiled ->
        compiled
    end
  end

  defp compile_all do
    %{
      subtitles: Enum.map(@subtitle_sources, &compile_bounded/1),
      tokens:
        Enum.map(@token_sources, fn %{patterns: patterns, languages: languages} ->
          %{patterns: Enum.map(patterns, &compile_bounded/1), languages: languages}
        end),
      combo: compile!(@combo_source)
    }
  end

  defp compile_bounded(source), do: compile!(@boundary_open <> source <> @boundary_close)

  defp compile!(source) do
    {:ok, pattern} = :re.compile(source, [:caseless, :unicode])
    pattern
  end
end
