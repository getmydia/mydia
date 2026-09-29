defmodule Mydia.Metadata.Countries do
  @moduledoc """
  ISO 3166-1 alpha-2 codes for the countries Discover can filter by origin.

  Curated rather than exhaustive, like `MydiaWeb.Languages`: TMDB's
  `with_origin_country` accepts any code, but a 249-entry menu buries the few
  dozen countries with a meaningful film and TV catalogue. Removing an entry is
  safe: `Mydia.Accounts.UserPreference.discover_home_country/1` reads a stored
  code that is no longer listed as unset.

  Lives under `Mydia.Metadata` rather than `MydiaWeb` because
  `UserPreference` validates against it.
  """

  @all [
    {"AR", "Argentina"},
    {"AU", "Australia"},
    {"AT", "Austria"},
    {"BE", "Belgium"},
    {"BR", "Brazil"},
    {"CA", "Canada"},
    {"CL", "Chile"},
    {"CN", "China"},
    {"CO", "Colombia"},
    {"CZ", "Czechia"},
    {"DK", "Denmark"},
    {"EG", "Egypt"},
    {"FI", "Finland"},
    {"FR", "France"},
    {"DE", "Germany"},
    {"GR", "Greece"},
    {"HK", "Hong Kong"},
    {"HU", "Hungary"},
    {"IS", "Iceland"},
    {"IN", "India"},
    {"ID", "Indonesia"},
    {"IR", "Iran"},
    {"IE", "Ireland"},
    {"IL", "Israel"},
    {"IT", "Italy"},
    {"JP", "Japan"},
    {"MX", "Mexico"},
    {"NL", "Netherlands"},
    {"NZ", "New Zealand"},
    {"NG", "Nigeria"},
    {"NO", "Norway"},
    {"PH", "Philippines"},
    {"PL", "Poland"},
    {"PT", "Portugal"},
    {"RO", "Romania"},
    {"RU", "Russia"},
    {"ZA", "South Africa"},
    {"KR", "South Korea"},
    {"ES", "Spain"},
    {"SE", "Sweden"},
    {"CH", "Switzerland"},
    {"TW", "Taiwan"},
    {"TH", "Thailand"},
    {"TR", "Turkey"},
    {"UA", "Ukraine"},
    {"GB", "United Kingdom"},
    {"US", "United States"}
  ]

  @names Map.new(@all)

  @doc "Every offered country as `{code, display_name}`, sorted by name."
  @spec all() :: [{String.t(), String.t()}]
  def all, do: @all

  @doc "Whether `code` is a listed, uppercase alpha-2 code."
  @spec valid_code?(term()) :: boolean()
  def valid_code?(code) when is_binary(code), do: Map.has_key?(@names, code)
  def valid_code?(_code), do: false

  @doc "Display name for a code, falling back to the code itself when unknown."
  @spec name(String.t()) :: String.t()
  def name(code), do: Map.get(@names, code, code)

  @doc """
  Flag emoji for an uppercase alpha-2 code: each letter maps to its Unicode
  regional indicator symbol. Anything else yields an empty string.
  """
  @spec flag(String.t()) :: String.t()
  def flag(<<a, b>>) when a in ?A..?Z and b in ?A..?Z,
    do: <<a - ?A + 0x1F1E6::utf8, b - ?A + 0x1F1E6::utf8>>

  def flag(_code), do: ""
end
