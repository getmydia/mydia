defmodule Mydia.Metadata.Structs.PersonSearchResult do
  @moduledoc """
  A hit from TMDB's person search.
  """

  @enforce_keys [:tmdb_id, :name]
  defstruct [:tmdb_id, :name, :profile_path, :known_for_department, known_for: []]

  @type t :: %__MODULE__{
          tmdb_id: integer(),
          name: String.t(),
          profile_path: String.t() | nil,
          known_for_department: String.t() | nil,
          known_for: [String.t()]
        }

  @doc """
  Builds a result from one entry of TMDB's `/search/person` `results` list.
  """
  @spec from_api_response(map()) :: t()
  def from_api_response(%{"id" => id} = data) do
    %__MODULE__{
      tmdb_id: id,
      name: data["name"] || "",
      profile_path: data["profile_path"],
      known_for_department: data["known_for_department"],
      known_for: known_for_titles(data["known_for"])
    }
  end

  defp known_for_titles(items) when is_list(items) do
    items
    |> Enum.map(fn item -> item["title"] || item["name"] end)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp known_for_titles(_), do: []
end
