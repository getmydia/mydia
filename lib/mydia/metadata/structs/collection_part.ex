defmodule Mydia.Metadata.Structs.CollectionPart do
  @moduledoc """
  One member movie of a TMDB collection (franchise).

  This is the trimmed shape TMDB returns inside a collection's `parts` list. It
  is not full movie metadata; fetch `MediaMetadata` by id for that.
  """

  @enforce_keys [:provider_id]
  defstruct [
    :provider_id,
    :title,
    :original_title,
    :overview,
    :release_date,
    :poster_path,
    :backdrop_path,
    :vote_average
  ]

  @type t :: %__MODULE__{
          provider_id: String.t(),
          title: String.t() | nil,
          original_title: String.t() | nil,
          overview: String.t() | nil,
          release_date: Date.t() | nil,
          poster_path: String.t() | nil,
          backdrop_path: String.t() | nil,
          vote_average: float() | nil
        }

  @doc """
  Creates a CollectionPart from a raw entry in a TMDB collection's `parts` list.
  """
  def from_api_response(data) when is_map(data) do
    %__MODULE__{
      provider_id: to_string(data["id"]),
      title: data["title"] || data["name"],
      original_title: data["original_title"],
      overview: data["overview"],
      release_date: parse_date(data["release_date"]),
      poster_path: data["poster_path"],
      backdrop_path: data["backdrop_path"],
      vote_average: data["vote_average"]
    }
  end

  defp parse_date(date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_), do: nil
end
