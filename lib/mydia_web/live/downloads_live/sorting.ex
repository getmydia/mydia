defmodule MydiaWeb.DownloadsLive.Sorting do
  @moduledoc """
  Sort options and ordering for the enriched downloads list.

  Real-time keys (progress, speeds, ETA, ratio) only exist after client-status
  enrichment, so sorting runs in the LiveView over the enriched list, not in
  the DB query.
  """

  alias MydiaWeb.DownloadsLive.ListView

  # Sort options offered per tab.
  @shared_sort_options [
    {"added_desc", "Newest first"},
    {"added_asc", "Oldest first"},
    {"name_asc", "Name (A-Z)"},
    {"name_desc", "Name (Z-A)"},
    {"status_asc", "Status"},
    {"size_desc", "Size (largest)"},
    {"size_asc", "Size (smallest)"}
  ]

  @queue_sort_options [
    {"progress_desc", "Progress (most)"},
    {"progress_asc", "Progress (least)"},
    {"dlspeed_desc", "Download speed"},
    {"eta_asc", "ETA (soonest)"}
  ]

  @completed_sort_options [
    {"ratio_desc", "Ratio (highest)"},
    {"ratio_asc", "Ratio (lowest)"},
    {"ulspeed_desc", "Upload speed"},
    {"imported_desc", "Imported (newest)"},
    {"imported_asc", "Imported (oldest)"}
  ]

  @allowed_sort_fields (@shared_sort_options ++ @queue_sort_options ++ @completed_sort_options)
                       |> Enum.map(&elem(&1, 0))

  # Rank for status sorting so states group sensibly (active work first) rather
  # than sorting alphabetically. Unknown statuses fall to the end.
  @status_rank %{
    "downloading" => 0,
    "checking" => 1,
    "queued" => 2,
    "paused" => 3,
    "stalled" => 4,
    "seeding" => 5,
    "completed" => 6,
    "imported" => 7,
    "cancelled" => 8,
    "failed" => 9,
    "missing" => 10,
    "unknown" => 11
  }

  @doc "Every `sort_by` value any tab offers."
  @spec allowed_fields() :: [String.t()]
  def allowed_fields, do: @allowed_sort_fields

  # Sort options available for the given tab. Shared keys apply to every tab;
  # queue- and completed-specific keys are only meaningful there.
  @doc "The `{value, label}` sort options offered on the given tab."
  @spec options(atom()) :: [{String.t(), String.t()}]
  def options(:completed), do: @shared_sort_options ++ @completed_sort_options
  def options(_tab), do: @shared_sort_options ++ @queue_sort_options

  # Sorts the enriched download list by the active `sort_by` selection. Runs in
  # the LiveView (not the DB) because real-time keys (progress, speeds, ETA,
  # ratio) only exist after client-status enrichment. Missing values are guarded
  # so they group deterministically rather than scatter or raise.
  @doc "Sorts the enriched download list by the `sort_by` selection."
  @spec sort([map()], String.t()) :: [map()]
  def sort(downloads, sort_by) do
    {key_fun, order} = sort_spec(sort_by)
    Enum.sort_by(downloads, key_fun, order)
  end

  defp sort_spec("added_desc"), do: {& &1.inserted_at, {:desc, DateTime}}
  defp sort_spec("added_asc"), do: {& &1.inserted_at, {:asc, DateTime}}
  defp sort_spec("name_asc"), do: {&sort_name/1, :asc}
  defp sort_spec("name_desc"), do: {&sort_name/1, :desc}
  defp sort_spec("status_asc"), do: {&status_rank/1, :asc}
  defp sort_spec("size_desc"), do: {&(&1.size || 0), :desc}
  defp sort_spec("size_asc"), do: {&(&1.size || 0), :asc}
  defp sort_spec("progress_desc"), do: {&(&1.progress || 0.0), :desc}
  defp sort_spec("progress_asc"), do: {&(&1.progress || 0.0), :asc}
  defp sort_spec("dlspeed_desc"), do: {&(&1.download_speed || 0), :desc}
  defp sort_spec("ulspeed_desc"), do: {&(&1.upload_speed || 0), :desc}
  defp sort_spec("ratio_desc"), do: {&(&1.ratio || 0.0), :desc}
  defp sort_spec("ratio_asc"), do: {&(&1.ratio || 0.0), :asc}
  defp sort_spec("eta_asc"), do: {&eta_sort_key/1, :asc}
  defp sort_spec("imported_desc"), do: {&imported_sort_key/1, {:desc, DateTime}}
  defp sort_spec("imported_asc"), do: {&imported_sort_key/1, {:asc, DateTime}}
  defp sort_spec(_unknown), do: {& &1.inserted_at, {:desc, DateTime}}

  defp sort_name(download), do: String.downcase(ListView.display_title(download))

  defp status_rank(download) do
    # Stall state overrides the client status for sorting: a soft-stall groups
    # with warnings.
    if ListView.soft_stalled?(download) do
      Map.fetch!(@status_rank, "stalled")
    else
      Map.get(@status_rank, download.status, 99)
    end
  end

  # ETA may be nil, an integer (seconds remaining), or a DateTime. Normalize to
  # an integer so a single comparator works; nil sorts last (soonest first).
  defp eta_sort_key(download) do
    case download.eta do
      nil -> 9_999_999_999
      %DateTime{} = dt -> DateTime.diff(dt, DateTime.utc_now(), :second)
      seconds when is_integer(seconds) -> seconds
      _ -> 9_999_999_999
    end
  end

  # imported_at is always present on the completed tab, but guard nil so the
  # comparator never raises if called on a mixed list.
  defp imported_sort_key(download), do: download.imported_at || download.inserted_at
end
