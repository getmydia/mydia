defmodule Mydia.Metadata.Structs.CrewMember do
  @moduledoc """
  Represents a crew member from TMDB metadata.

  This struct provides compile-time safety for crew information from TMDB API
  responses, replacing plain map access that can silently return nil.

  Crew members represent people who worked on a movie or TV show in roles like
  Director, Producer, Writer, etc.
  """

  @enforce_keys [:name, :job]

  defstruct [
    :name,
    :job,
    :department,
    :profile_path
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          job: String.t(),
          department: String.t() | nil,
          profile_path: String.t() | nil
        }

  @doc """
  Creates a new CrewMember struct from a map or keyword list.

  ## Examples

      iex> new(name: "Lana Wachowski", job: "Director", department: "Directing")
      %CrewMember{
        name: "Lana Wachowski",
        job: "Director",
        department: "Directing",
        profile_path: nil
      }

      iex> new(name: "Joel Silver", job: "Producer", department: "Production", profile_path: "/xyz789.jpg")
      %CrewMember{
        name: "Joel Silver",
        job: "Producer",
        department: "Production",
        profile_path: "/xyz789.jpg"
      }
  """
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    struct(__MODULE__, attrs)
  end
end
