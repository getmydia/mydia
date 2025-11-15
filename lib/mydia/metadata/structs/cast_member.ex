defmodule Mydia.Metadata.Structs.CastMember do
  @moduledoc """
  Represents a cast member from TMDB metadata.

  This struct provides compile-time safety for cast information from TMDB API
  responses, replacing plain map access that can silently return nil.

  Cast members represent actors and their character names in movies and TV shows.
  """

  @enforce_keys [:name]

  defstruct [
    :name,
    :character,
    :order,
    :profile_path
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          character: String.t() | nil,
          order: integer() | nil,
          profile_path: String.t() | nil
        }

  @doc """
  Creates a new CastMember struct from a map or keyword list.

  ## Examples

      iex> new(name: "Keanu Reeves", character: "Neo", order: 0)
      %CastMember{
        name: "Keanu Reeves",
        character: "Neo",
        order: 0,
        profile_path: nil
      }

      iex> new(name: "Laurence Fishburne", character: "Morpheus", order: 1, profile_path: "/abc123.jpg")
      %CastMember{
        name: "Laurence Fishburne",
        character: "Morpheus",
        order: 1,
        profile_path: "/abc123.jpg"
      }
  """
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    struct(__MODULE__, attrs)
  end
end
