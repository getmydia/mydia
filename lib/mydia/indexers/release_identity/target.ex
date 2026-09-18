defmodule Mydia.Indexers.ReleaseIdentity.Target do
  @moduledoc """
  What a release has to match to be a given media item: the match keys of its
  title and alternative titles, and its year.

  Built from the `%MediaItem{}` alone, with no preloads, so every search path
  can build one from the item it already holds.
  """

  alias Mydia.Library.ReleaseParser.TargetContext
  alias Mydia.Library.Text
  alias Mydia.Media.MediaItem

  @enforce_keys [:type, :keys]
  defstruct [:type, :year, keys: []]

  @type t :: %__MODULE__{
          type: :movie | :tv_show,
          year: integer() | nil,
          keys: [String.t()]
        }

  # Show titles carry a disambiguating year, "Dark Lantern (2024)", that
  # release names write as a separate token or leave out.
  @year_suffix ~r/\s*\((19|20)\d{2}\)\s*$/

  @spec from_media_item(MediaItem.t()) :: t()
  def from_media_item(%MediaItem{} = item) do
    title = String.replace(item.title || "", @year_suffix, "")

    %__MODULE__{
      type: type(item.type),
      year: item.year,
      keys:
        [title | TargetContext.alt_titles(item)]
        |> Enum.map(&Text.match_key/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
    }
  end

  defp type("movie"), do: :movie
  defp type("tv_show"), do: :tv_show
end
