defmodule Mydia.Indexers.IdentityShadow do
  @moduledoc """
  Runs `Mydia.Indexers.ReleaseIdentity` beside the legacy title gate on live
  automatic searches, without changing what gets grabbed.

  Each call ranks a search's candidates twice: once exactly as automatic
  search does, and once with the identity check in place of the Jaro title
  gate. When the two top picks are different releases it records a
  `search.identity_shadow` event naming both, so the identity check can be
  judged against real searches before it replaces the title gate.
  """

  alias Mydia.Events
  alias Mydia.Indexers.{ReleaseIdentity, ReleaseRanker, SearchResult}
  alias Mydia.Media.MediaItem

  @max_rejections 10

  @doc """
  Compares the two gates' top picks for `candidates`. Returns `nil` when they
  agree, or when `ranking_opts` carries no `:identity_target`; otherwise the
  event metadata describing the disagreement.
  """
  @spec compare([SearchResult.t()], keyword()) :: map() | nil
  def compare(candidates, ranking_opts) do
    case Keyword.get(ranking_opts, :identity_target) do
      nil -> nil
      target -> compare(candidates, ranking_opts, target)
    end
  end

  @doc """
  Compares the gates for one automatic search and records a
  `search.identity_shadow` event when they disagree. `metadata` is merged into
  the event (the query, and for a season pack the season); `event_opts` goes
  to `Mydia.Events.search_identity_shadow/3`.
  """
  @spec observe(MediaItem.t(), [SearchResult.t()], keyword(), map(), keyword()) :: :ok
  def observe(%MediaItem{} = media_item, candidates, ranking_opts, metadata, event_opts \\ []) do
    case compare(candidates, ranking_opts) do
      nil ->
        :ok

      diff ->
        Events.search_identity_shadow(media_item, Map.merge(metadata, diff), event_opts)
        :ok
    end
  end

  defp compare(candidates, ranking_opts, target) do
    legacy =
      ReleaseRanker.rank_all(candidates, Keyword.put(ranking_opts, :identity_gate, :legacy))

    exact = ReleaseRanker.rank_all(candidates, Keyword.put(ranking_opts, :identity_gate, :exact))
    legacy_pick = top(legacy)
    exact_pick = top(exact)

    if legacy_pick == exact_pick do
      nil
    else
      %{
        "legacy_pick" => title(legacy_pick),
        "legacy_pick_verdict" => verdict(legacy_pick, target),
        "exact_pick" => title(exact_pick),
        "legacy_candidates" => length(legacy),
        "exact_candidates" => length(exact),
        "rejections" => rejections(legacy, target)
      }
    end
  end

  defp top([%{result: result} | _]), do: result
  defp top([]), do: nil

  defp title(nil), do: nil
  defp title(%SearchResult{title: title}), do: title

  defp verdict(nil, _target), do: nil

  defp verdict(%SearchResult{title: title}, target) do
    case ReleaseIdentity.check(title, target) do
      :match -> "match"
      {:mismatch, reason} -> "mismatch: #{reason}"
    end
  end

  # Legacy survivors the identity check would remove, in legacy rank order.
  defp rejections(ranked, target) do
    ranked
    |> Enum.flat_map(fn %{result: result} ->
      case ReleaseIdentity.check(result.title, target) do
        :match -> []
        {:mismatch, reason} -> [%{"title" => result.title, "reason" => Atom.to_string(reason)}]
      end
    end)
    |> Enum.take(@max_rejections)
  end
end
