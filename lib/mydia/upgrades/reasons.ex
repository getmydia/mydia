defmodule Mydia.Upgrades.Reasons do
  @moduledoc """
  Why an upgrade search runs, and the backoff bucket each reason owns.

  A file below its quality cutoff and a file missing its preferred audio
  language share one indexer query when both apply to the same movie or
  episode, but they back off and give up independently. A show whose dub has
  not been released yet must not stop its quality upgrades, and a file with no
  better encode must not stop its dub from being found.

  Reasons travel through Oban args as strings. A job enqueued before reasons
  existed carries none and is read as a quality search, which is all it could
  have been.
  """

  @type reason :: :quality | :language
  @type kind :: :movie | :episode | :season

  @order [:quality, :language]

  @buckets %{
    {:movie, :quality} => "movie_upgrade",
    {:movie, :language} => "movie_language_upgrade",
    {:episode, :quality} => "episode_upgrade",
    {:episode, :language} => "episode_language_upgrade",
    {:season, :quality} => "season_upgrade",
    {:season, :language} => "season_language_upgrade"
  }

  @doc "Reasons as Oban arg strings, quality first."
  @spec encode([reason()]) :: [String.t()]
  def encode(reasons), do: reasons |> order() |> Enum.map(&Atom.to_string/1)

  @doc "Reasons read back from Oban args. Missing or unrecognized reads as `[:quality]`."
  @spec decode(term()) :: [reason()]
  def decode(values) when is_list(values) do
    values
    |> Enum.flat_map(fn
      "quality" -> [:quality]
      "language" -> [:language]
      _ -> []
    end)
    |> order()
    |> case do
      [] -> [:quality]
      reasons -> reasons
    end
  end

  def decode(_values), do: [:quality]

  @doc "The `SearchBackoff` resource type `reason` records against for `kind`."
  @spec bucket(kind(), reason()) :: String.t()
  def bucket(kind, reason), do: Map.fetch!(@buckets, {kind, reason})

  @doc "One bucket per reason, quality first."
  @spec buckets(kind(), [reason()]) :: [String.t()]
  def buckets(kind, reasons), do: reasons |> order() |> Enum.map(&bucket(kind, &1))

  defp order(reasons), do: Enum.filter(@order, &(&1 in reasons))
end
