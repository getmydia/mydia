defmodule MydiaWeb.DownloadsLive.Sorting do
  @moduledoc """
  Sort options and ordering for the enriched downloads list.

  Real-time keys (progress, speeds, ETA, ratio) only exist after client-status
  enrichment, so sorting runs in the LiveView over the enriched list, not in
  the DB query.
  """

  use Gettext, backend: MydiaWeb.Gettext

  alias MydiaWeb.DownloadsLive.ListView

  # Sort option keys offered per Downloads view. Labels come from
  # sort_label/1 so they are translated at render time.
  @shared_sort_options ~w(added_desc added_asc name_asc name_desc status_asc size_desc size_asc)

  @queue_sort_options ~w(progress_desc progress_asc dlspeed_desc eta_asc)

  @completed_sort_options ~w(ratio_desc ratio_asc ulspeed_desc imported_desc imported_asc)

  @allowed_sort_fields @shared_sort_options ++ @queue_sort_options ++ @completed_sort_options

  defp sort_label("added_desc"), do: gettext("Newest first")
  defp sort_label("added_asc"), do: gettext("Oldest first")
  defp sort_label("name_asc"), do: gettext("Name (A-Z)")
  defp sort_label("name_desc"), do: gettext("Name (Z-A)")
  defp sort_label("status_asc"), do: gettext("Status")
  defp sort_label("size_desc"), do: gettext("Size (largest)")
  defp sort_label("size_asc"), do: gettext("Size (smallest)")
  defp sort_label("progress_desc"), do: gettext("Progress (most)")
  defp sort_label("progress_asc"), do: gettext("Progress (least)")
  defp sort_label("dlspeed_desc"), do: gettext("Download speed")
  defp sort_label("eta_asc"), do: gettext("ETA (soonest)")
  defp sort_label("ratio_desc"), do: gettext("Ratio (highest)")
  defp sort_label("ratio_asc"), do: gettext("Ratio (lowest)")
  defp sort_label("ulspeed_desc"), do: gettext("Upload speed")
  defp sort_label("imported_desc"), do: gettext("Imported (newest)")
  defp sort_label("imported_asc"), do: gettext("Imported (oldest)")

  defp labeled(keys), do: Enum.map(keys, &{&1, sort_label(&1)})

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

  @doc "Every `sort_by` value any view offers."
  @spec allowed_fields() :: [String.t()]
  def allowed_fields, do: @allowed_sort_fields

  # Shared keys apply to every view. Progress, speed and ETA only mean
  # something in flight; ratio and import date only once imported. All mixes
  # both kinds of row, so it offers both sets.
  @doc "The `{value, label}` sort options offered in the given Downloads view."
  @spec options(:active | :imported | :all) :: [{String.t(), String.t()}]
  def options(:imported), do: labeled(@shared_sort_options ++ @completed_sort_options)

  def options(:all),
    do: labeled(@shared_sort_options ++ @queue_sort_options ++ @completed_sort_options)

  def options(_view), do: labeled(@shared_sort_options ++ @queue_sort_options)

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

  # imported_at is present on imported rows; the All view also sorts in-flight
  # rows, which fall back to inserted_at.
  defp imported_sort_key(download), do: download.imported_at || download.inserted_at
end
