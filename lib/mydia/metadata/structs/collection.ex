defmodule Mydia.Metadata.Structs.Collection do
  @moduledoc """
  A TMDB movie collection: the franchise a movie belongs to, plus its members.

  Named for the provider's vocabulary, matching its siblings in this directory.
  The library-facing view model is `Mydia.Media.Franchise`, which is deliberately
  named differently so it does not collide with `Mydia.Collections` (user-curated
  lists).
  """

  alias Mydia.Metadata.Structs.CollectionPart

  @enforce_keys [:provider_id]
  defstruct [:provider_id, :name, :overview, :poster_path, :backdrop_path, parts: []]

  @type t :: %__MODULE__{
          provider_id: String.t(),
          name: String.t() | nil,
          overview: String.t() | nil,
          poster_path: String.t() | nil,
          backdrop_path: String.t() | nil,
          parts: [CollectionPart.t()]
        }

  @doc """
  Creates a Collection from a raw TMDB `/collection/{id}` response.
  """
  def from_api_response(data) when is_map(data) do
    %__MODULE__{
      provider_id: to_string(data["id"]),
      name: data["name"],
      overview: data["overview"],
      poster_path: data["poster_path"],
      backdrop_path: data["backdrop_path"],
      parts: parse_parts(data["parts"])
    }
  end

  defp parse_parts(parts) when is_list(parts),
    do: Enum.map(parts, &CollectionPart.from_api_response/1)

  defp parse_parts(_), do: []
end
