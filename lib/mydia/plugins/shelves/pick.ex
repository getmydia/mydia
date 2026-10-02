defmodule Mydia.Plugins.Shelves.Pick do
  @moduledoc """
  One title a plugin proposed for a shelf, before the host has verified it.
  Also the shape of an `exclude` entry handed to the plugin, where `reason` is
  unused.
  """

  defstruct [:media_type, :tmdb_id, :tvdb_id, :imdb_id, :reason]

  @type t :: %__MODULE__{
          media_type: :movie | :tv_show | nil,
          tmdb_id: integer() | nil,
          tvdb_id: integer() | nil,
          imdb_id: String.t() | nil,
          reason: String.t() | nil
        }

  @doc """
  Builds a pick from a normalised `shelf-item` record. A media type the host
  does not know becomes `nil`, which the verifier drops; it is never turned
  into an atom.
  """
  @spec from_wit(map()) :: t()
  def from_wit(%{item: %{} = item} = wit) do
    %__MODULE__{
      media_type: media_type(Map.get(item, :media_type)),
      tmdb_id: integer(Map.get(item, :tmdb_id)),
      tvdb_id: integer(Map.get(item, :tvdb_id)),
      imdb_id: string(Map.get(item, :imdb_id)),
      reason: string(Map.get(wit, :reason))
    }
  end

  def from_wit(_other), do: %__MODULE__{}

  defp media_type("movie"), do: :movie
  defp media_type("tv_show"), do: :tv_show
  defp media_type(_), do: nil

  defp integer(n) when is_integer(n) and n > 0, do: n
  defp integer(_), do: nil

  defp string(s) when is_binary(s), do: s
  defp string(_), do: nil
end
