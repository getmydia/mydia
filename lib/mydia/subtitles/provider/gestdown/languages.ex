defmodule Mydia.Subtitles.Provider.Gestdown.Languages do
  @moduledoc """
  Translates between ISO 639-1 codes and the language names Gestdown uses.

  Gestdown takes a language as a full English name in the request path, and
  returns the same name on each result. Everything else in Mydia speaks ISO
  639-1, so the translation lives here rather than being scattered through the
  adapter.

  An unknown code returns `:error` and the adapter skips that language. Guessing
  a name would spend a request to be told nothing, and inventing one from the
  code would be wrong for every language whose English name is not its code.
  """

  # Gestdown carries Addic7ed's language list. These are the codes Mydia is
  # likely to be asked for, mapped to the exact names the API returns. Add
  # entries as needed rather than deriving names, because several are irregular:
  # Addic7ed distinguishes Brazilian Portuguese from Portuguese, and both map
  # back to "pt".
  @to_name %{
    "ar" => "Arabic",
    "bg" => "Bulgarian",
    "ca" => "Catalan",
    "cs" => "Czech",
    "da" => "Danish",
    "de" => "German",
    "el" => "Greek",
    "en" => "English",
    "es" => "Spanish",
    "eu" => "Euskera",
    "fa" => "Persian",
    "fi" => "Finnish",
    "fr" => "French",
    "gl" => "Galician",
    "he" => "Hebrew",
    "hr" => "Croatian",
    "hu" => "Hungarian",
    "id" => "Indonesian",
    "it" => "Italian",
    "ja" => "Japanese",
    "ko" => "Korean",
    "nl" => "Dutch",
    "no" => "Norwegian",
    "pl" => "Polish",
    "pt" => "Portuguese",
    "ro" => "Romanian",
    "ru" => "Russian",
    "sk" => "Slovak",
    "sl" => "Slovenian",
    "sr" => "Serbian",
    "sv" => "Swedish",
    "th" => "Thai",
    "tr" => "Turkish",
    "uk" => "Ukrainian",
    "vi" => "Vietnamese",
    "zh" => "Chinese (Simplified)"
  }

  # Extra names Gestdown may return that collapse onto a code already mapped
  # above. Kept separate so `to_name/1` stays a clean one-to-one table.
  @extra_to_code %{
    "Brazilian Portuguese" => "pt",
    "Portuguese (Brazilian)" => "pt",
    "Chinese (Traditional)" => "zh",
    "Spanish (Latin America)" => "es",
    "Spanish (Spain)" => "es",
    "French (Canadian)" => "fr"
  }

  @to_code @to_name
           |> Enum.map(fn {code, name} -> {name, code} end)
           |> Enum.into(%{})
           |> Map.merge(@extra_to_code)

  @doc """
  Returns the Gestdown language name for an ISO 639-1 code.
  """
  @spec to_name(String.t()) :: {:ok, String.t()} | :error
  def to_name(code) when is_binary(code) do
    case Map.fetch(@to_name, String.downcase(code)) do
      {:ok, name} -> {:ok, name}
      :error -> :error
    end
  end

  def to_name(_code), do: :error

  @doc """
  Returns the ISO 639-1 code for a Gestdown language name.
  """
  @spec to_code(String.t()) :: {:ok, String.t()} | :error
  def to_code(name) when is_binary(name) do
    case Map.fetch(@to_code, name) do
      {:ok, code} -> {:ok, code}
      :error -> :error
    end
  end

  def to_code(_name), do: :error
end
