defmodule Mydia.Indexers.GrabDelay do
  @moduledoc """
  Decides whether an automatic search grabs its best release now or waits for
  better ones, per the quality profile's `grab_delay_hours`.

  The clock starts at the oldest `published_at` in the ranked list, which the
  automatic path has already cut down to releases acceptable to the profile
  (and, on an upgrade, to real upgrades). A newer release never restarts it,
  so a steady trickle of new uploads cannot postpone a grab forever, and a
  backlog item whose releases are long out grabs at once.

  Three things grab immediately: `bypass: true` (a search the user started),
  a delay of 0, and a best release that already scores at or above
  `upgrade_until_score`. That last check uses the file-scale score the upgrade
  cutoff is compared against (`Mydia.Upgrades.Comparator.below_cutoff?/3`),
  never `RankedResult.score`, which mixes in seeders and title match. Waiting
  for a release the upgrade path would never replace gains nothing.

  A release with no `published_at` counts as old, so a missing date never
  blocks a grab.
  """

  alias Mydia.Indexers.{ProfileLimits, SearchScorer}
  alias Mydia.Indexers.Structs.RankedResult
  alias Mydia.Settings.QualityProfile

  @type decision ::
          :none | {:grab, RankedResult.t()} | {:wait, DateTime.t(), RankedResult.t()}

  @spec select([RankedResult.t()], keyword(), DateTime.t(), keyword()) :: decision()
  def select(ranked, ranking_opts, now, opts \\ [])

  def select([], _ranking_opts, _now, _opts), do: :none

  def select([best | _] = ranked, ranking_opts, now, opts) do
    profile = Keyword.get(ranking_opts, :quality_profile)
    hours = delay_hours(profile)

    cond do
      Keyword.get(opts, :bypass, false) -> {:grab, best}
      hours == 0 -> {:grab, best}
      meets_cutoff?(best, profile, ranking_opts) -> {:grab, best}
      true -> by_age(ranked, best, hours, now)
    end
  end

  defp delay_hours(%QualityProfile{grab_delay_hours: hours}) when is_integer(hours) and hours > 0,
    do: hours

  defp delay_hours(_profile), do: 0

  defp meets_cutoff?(_best, %QualityProfile{upgrade_until_score: nil}, _ranking_opts), do: false

  defp meets_cutoff?(%RankedResult{result: result}, %QualityProfile{} = profile, ranking_opts) do
    # A season pack is scored per episode, as ProfileLimits judges it.
    sized = ProfileLimits.per_episode_sized(result, Keyword.get(ranking_opts, :episode_count))
    media_type = Keyword.get(ranking_opts, :media_type, :movie)
    {score, _breakdown, _violations} = SearchScorer.score_quality(sized, profile, media_type)

    score >= profile.upgrade_until_score
  end

  defp by_age(ranked, best, hours, now) do
    dates = Enum.map(ranked, & &1.result.published_at)

    if Enum.any?(dates, &is_nil/1) do
      {:grab, best}
    else
      until = dates |> Enum.min(DateTime) |> DateTime.add(hours * 3600, :second)

      if DateTime.compare(now, until) == :lt, do: {:wait, until, best}, else: {:grab, best}
    end
  end
end
