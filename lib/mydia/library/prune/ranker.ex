defmodule Mydia.Library.Prune.Ranker do
  @moduledoc """
  Picks which file in an eligible group to keep.

  Two rankers. When the item has a quality profile and the files are analyzed,
  `Mydia.Upgrades.Comparator` scores them, so prune agrees with whatever the
  operator already configured as better. Otherwise a fixed fallback runs.

  ## Why the fallback puts codec last

  An earlier draft ranked codec right after resolution, reasoning that a more
  efficient codec is a better file. Against real data that is harmful. Jujutsu
  Kaisen S03E03 exists as 1080p h264 at 8.8 Mbps (1.58 GB), h264 at 5.0 Mbps,
  and av1 at 2.9 Mbps (520 MB). Codec-second keeps the 520 MB av1 and trashes
  the source. Codec efficiency describes quality per bit; it does not make a
  low-bitrate re-encode better than a high-bitrate source.

  Since the fallback only runs for items with no quality profile, the
  conservative ordering is the right default. An operator who genuinely prefers
  av1 says so in a quality profile, which takes the profile path instead.

  The keeper is a proposal. `decide/2` lets the operator name a different one.
  """

  alias Mydia.Library.{FileRanking, MediaFile}
  alias Mydia.Library.Prune.{Decision, Group}
  alias Mydia.Upgrades.Comparator

  # Only a tiebreak, and only among files that already tie on resolution,
  # bitrate and size.
  @codec_rank %{"av1" => 4, "hevc" => 3, "h265" => 3, "h264" => 2, "avc" => 2, "mpeg4" => 1}

  @doc """
  Ranks `group` and returns the decision, keeping the highest-ranked file.
  """
  @spec decide(Group.t()) :: Decision.t()
  def decide(%Group{} = group), do: decide(group, nil)

  @doc """
  Like `decide/1`, but keeps `keeper_id` when it names a file in the group.

  An id that is not in the group is ignored rather than raising: the page can
  race a rescan, and silently falling back to the ranked keeper is safer than
  crashing a LiveView mid-review.
  """
  @spec decide(Group.t(), String.t() | nil) :: Decision.t()
  def decide(%Group{files: files} = group, keeper_id) do
    {ranker, sorted} = rank(group)

    keeper =
      Enum.find(files, fn file -> keeper_id != nil and file.id == keeper_id end) || hd(sorted)

    %Decision{
      group: group,
      keeper: keeper,
      # Rank order, not the order the files came back from the database. The
      # review page lists `[keeper | losers]` and promotes the first loser
      # when the operator trashes the keeper, so both depend on the best
      # remaining copy coming first.
      losers: Enum.reject(sorted, &(&1.id == keeper.id)),
      ranker: ranker,
      reason: reason_for(ranker, keeper)
    }
  end

  defp rank(%Group{media_item: media_item, files: files} = group) do
    media_type = if group.subject_type == :episode, do: :episode, else: :movie

    profile =
      case Map.get(media_item, :quality_profile) do
        %Ecto.Association.NotLoaded{} -> nil
        other -> other
      end

    scored =
      if profile do
        Enum.map(files, fn file ->
          case Comparator.score_file(file, profile, media_type) do
            {:ok, score} -> {file, score}
            {:error, :unscorable} -> {file, nil}
          end
        end)
      else
        Enum.map(files, &{&1, nil})
      end

    if profile && Enum.all?(scored, fn {_file, score} -> score != nil end) do
      {:profile,
       scored |> Enum.sort_by(fn {_file, score} -> score end, :desc) |> Enum.map(&elem(&1, 0))}
    else
      {:fallback, Enum.sort_by(files, &fallback_key/1, :desc)}
    end
  end

  # Sorted descending, so every component is "bigger is better". `inserted_at`
  # is negated so that a larger key means an *older* file, which keeps the
  # oldest on a tie. `id` last makes the order total, so two files inserted in
  # the same second still rank deterministically and a re-run proposes the same
  # keeper.
  defp fallback_key(%MediaFile{} = file) do
    {
      FileRanking.resolution_pixels(file.resolution),
      file.bitrate || 0,
      file.size || 0,
      codec_rank(file.codec),
      -DateTime.to_unix(file.inserted_at),
      file.id
    }
  end

  defp codec_rank(nil), do: 0

  defp codec_rank(codec) when is_binary(codec) do
    Map.get(@codec_rank, String.downcase(String.trim(codec)), 0)
  end

  defp codec_rank(_other), do: 0

  defp reason_for(:profile, keeper),
    do: "Highest quality profile score (#{describe(keeper)})"

  defp reason_for(:fallback, keeper),
    do: "No quality profile, ranked by resolution then bitrate (#{describe(keeper)})"

  defp describe(%MediaFile{} = file) do
    [file.resolution, file.codec, bitrate_label(file.bitrate)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp bitrate_label(nil), do: nil
  defp bitrate_label(bitrate), do: "#{Float.round(bitrate / 1_000_000, 1)} Mbps"
end
