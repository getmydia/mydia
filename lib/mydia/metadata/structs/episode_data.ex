defmodule Mydia.Metadata.Structs.EpisodeData do
  @moduledoc """
  Represents episode data from TMDB via the metadata relay service.

  This struct provides compile-time safety for episode data, replacing
  plain map access that can silently return nil.
  """

  alias Mydia.Metadata.LanguageCode

  @enforce_keys [:season_number, :episode_number]
  defstruct [
    # Required fields
    :season_number,
    :episode_number,
    # Optional fields
    :name,
    :overview,
    :air_date,
    :runtime,
    :still_path,
    :vote_average,
    :vote_count,
    :absolute_number,
    :provider_episode_id
  ]

  @type t :: %__MODULE__{
          season_number: integer(),
          episode_number: integer(),
          name: String.t() | nil,
          overview: String.t() | nil,
          air_date: Date.t() | nil,
          runtime: integer() | nil,
          still_path: String.t() | nil,
          vote_average: float() | nil,
          vote_count: integer() | nil,
          absolute_number: integer() | nil,
          provider_episode_id: String.t() | nil
        }

  @doc """
  Creates an EpisodeData struct from a raw API response map.

  ## Examples

      iex> from_api_response(%{"season_number" => 1, "episode_number" => 1, ...})
      %EpisodeData{season_number: 1, episode_number: 1, ...}
  """
  def from_api_response(data) when is_map(data) do
    %__MODULE__{
      season_number: data["season_number"],
      episode_number: data["episode_number"],
      name: data["name"],
      overview: data["overview"],
      air_date: parse_date(data["air_date"]),
      runtime: data["runtime"],
      still_path: data["still_path"],
      vote_average: data["vote_average"],
      vote_count: data["vote_count"],
      absolute_number: nil,
      provider_episode_id: nil
    }
  end

  @doc """
  Creates an EpisodeData struct from a TVDB API response map.

  TVDB uses different field names: `seasonNumber`, `number`, `name`,
  `overview`, `aired`, `runtime`, `image`.

  `preferred_codes` is an ordered list of TVDB (ISO 639-2/T) language codes to
  try when selecting the localized name/overview, falling back to the raw
  fields. Defaults to `["eng"]` to preserve prior English-only behavior.
  """
  def from_tvdb_response(data, preferred_codes \\ ["eng"]) when is_map(data) do
    # Episodes within season responses may not include translations — falls
    # back gracefully to the raw name/overview.
    translations = data["translations"] || %{}

    localized_name =
      LanguageCode.select_translation(translations["nameTranslations"], "name", preferred_codes)

    localized_overview =
      LanguageCode.select_translation(
        translations["overviewTranslations"],
        "overview",
        preferred_codes
      )

    %__MODULE__{
      season_number: data["seasonNumber"],
      episode_number: data["number"],
      name: localized_name || data["name"],
      overview: localized_overview || data["overview"],
      air_date: parse_date(data["aired"]),
      runtime: data["runtime"],
      still_path: data["image"],
      absolute_number: data["absoluteNumber"],
      provider_episode_id: stringify_id(data["id"])
    }
  end

  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil

  defp parse_date(date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  # TVDB ids arrive as integers; they are stored as text so the column can hold
  # a TMDB id later without a type change.
  defp stringify_id(nil), do: nil
  defp stringify_id(id) when is_integer(id), do: Integer.to_string(id)
  defp stringify_id(id) when is_binary(id), do: id
end
