defmodule Mydia.Locale do
  @moduledoc """
  The interface languages Mydia ships, and which one a request gets.

  A language is available when `priv/gettext/<code>/LC_MESSAGES/` contains a
  `.po` file; an empty directory does not count. `en` always is, because msgids
  are the English text. Weblate adds the catalogs, so a new language appears
  with the first release that carries its translations. Untranslated messages
  fall back to English.

  Resolution order (`resolve/4`): the user's `interface_language` preference,
  then the browser's `Accept-Language`, then the instance default
  (`ui.default_locale`), then `en`. A code nobody translated is skipped at
  every step, never an error.
  """

  alias Mydia.Locale.{Catalog, Info}

  @gettext_dir Path.expand("../../priv/gettext", __DIR__)
  @po_files Catalog.po_files(@gettext_dir)
  for file <- @po_files, do: @external_resource(file)
  @po_hash :erlang.md5(Enum.map(@po_files, &[&1, File.read!(&1)]))

  @counts Catalog.scan(@gettext_dir)

  @native_names %{
    "ar" => "العربية",
    "cs" => "Čeština",
    "da" => "Dansk",
    "de" => "Deutsch",
    "en" => "English",
    "es" => "Español",
    "fi" => "Suomi",
    "fr" => "Français",
    "he" => "עברית",
    "hu" => "Magyar",
    "it" => "Italiano",
    "ja" => "日本語",
    "ko" => "한국어",
    "nb_NO" => "Norsk bokmål",
    "nl" => "Nederlands",
    "pl" => "Polski",
    "pt" => "Português",
    "pt_BR" => "Português (Brasil)",
    "ru" => "Русский",
    "sv" => "Svenska",
    "tr" => "Türkçe",
    "uk" => "Українська",
    "zh_Hans" => "简体中文",
    "zh_Hant" => "繁體中文"
  }

  @codes ["en" | @counts |> Map.keys() |> List.delete("en")] |> Enum.uniq() |> Enum.sort()

  @infos (for code <- ["en" | List.delete(@codes, "en")] do
            completion =
              case {code, Map.get(@counts, code)} do
                {"en", _} -> 1.0
                {_, {_done, 0}} -> 0.0
                {_, {done, total}} -> done / total
                {_, nil} -> 0.0
              end

            %Info{
              code: code,
              native_name: Map.get(@native_names, code, code),
              completion: completion
            }
          end)

  @doc false
  def __mix_recompile__? do
    files = Catalog.po_files(@gettext_dir)
    :erlang.md5(Enum.map(files, &[&1, File.read!(&1)])) != @po_hash
  end

  @spec codes() :: [String.t()]
  def codes, do: @codes

  @spec available() :: [Info.t()]
  def available, do: @infos

  @spec available?(term()) :: boolean()
  def available?(code), do: code in @codes

  @spec completion(String.t()) :: float()
  def completion(code) do
    case Enum.find(@infos, &(&1.code == code)) do
      %Info{completion: c} -> c
      nil -> 0.0
    end
  end

  @doc "The instance default from `ui.default_locale`, or `\"en\"`."
  @spec instance_default() :: String.t()
  def instance_default do
    case Mydia.Config.get() do
      %{ui: %{default_locale: code}} when is_binary(code) and code != "" -> code
      _ -> "en"
    end
  end

  @doc "Picks the request's locale. See the moduledoc for the order."
  @spec resolve(String.t() | nil, String.t() | nil, String.t() | nil, [String.t()]) ::
          String.t()
  def resolve(preference, accept_language, instance_default, available \\ @codes) do
    browser =
      accept_language
      |> parse_accept_language()
      |> Enum.find_value(&match(&1, available))

    cond do
      preference in available -> preference
      browser -> browser
      instance_default in available -> instance_default
      true -> "en"
    end
  end

  @doc """
  The user's preference when it names an available locale, otherwise
  `fallback` (normally the browser locale the plug resolved), otherwise `en`.
  """
  @spec with_preference(String.t() | nil, String.t() | nil, [String.t()]) :: String.t()
  def with_preference(preference, fallback, available \\ @codes) do
    cond do
      preference in available -> preference
      fallback in available -> fallback
      true -> "en"
    end
  end

  @doc "BCP 47 form for `<html lang>`: `pt_BR` becomes `pt-BR`."
  @spec html_lang(String.t()) :: String.t()
  def html_lang(code), do: String.replace(code, "_", "-")

  # Tags in descending q order; equal q keeps header order (Enum.sort_by is
  # stable). q=0 means "not acceptable" and is dropped.
  defp parse_accept_language(header) when is_binary(header) do
    header
    |> String.split(",")
    |> Enum.flat_map(&parse_entry/1)
    |> Enum.sort_by(fn {_tag, q} -> q end, :desc)
    |> Enum.map(fn {tag, _q} -> tag end)
  end

  defp parse_accept_language(_), do: []

  defp parse_entry(entry) do
    [tag | params] = entry |> String.split(";") |> Enum.map(&String.trim/1)
    q = Enum.find_value(params, 1.0, &parse_q/1)

    if q > 0 and Regex.match?(~r/\A[A-Za-z]{2,3}([-_][A-Za-z0-9]{1,8})*\z/, tag),
      do: [{tag, q}],
      else: []
  end

  defp parse_q("q=" <> value) do
    case Float.parse(value) do
      {q, _} -> q
      :error -> 0.0
    end
  end

  defp parse_q(_), do: nil

  # "pt-br" -> tries "pt_BR", then "pt". "zh-Hant-TW" -> "zh_Hant_TW", then "zh".
  defp match(tag, available) do
    [lang | rest] = String.split(tag, ["-", "_"])
    lang = String.downcase(lang)
    exact = Enum.join([lang | Enum.map(rest, &normalize_subtag/1)], "_")

    Enum.find([exact, lang], &(&1 in available))
  end

  defp normalize_subtag(<<_::binary-size(2)>> = region), do: String.upcase(region)

  defp normalize_subtag(<<first::binary-size(1), rest::binary-size(3)>>),
    do: String.upcase(first) <> String.downcase(rest)

  defp normalize_subtag(other), do: other
end
