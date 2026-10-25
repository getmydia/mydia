defmodule MydiaWeb.ImportMediaLive.Messages do
  @moduledoc """
  Translated flash text for the Import Media page's bulk actions.
  """

  use Gettext, backend: MydiaWeb.Gettext

  # `ImportCandidates.clear_for_library/1` deletes every undismissed
  # candidate and finished run history for the library, but preserves
  # dismissed candidates -- naming that explicitly is what keeps a reviewer
  # from reading "Cleared" as "every decision I made is gone".
  def cleared_message(%{candidates: 0}) do
    gettext("Nothing to clear. Dismissed decisions are preserved.")
  end

  def cleared_message(%{candidates: candidates}) do
    ngettext(
      "Cleared %{count} scan result. Dismissed decisions are preserved.",
      "Cleared %{count} scan results. Dismissed decisions are preserved.",
      candidates
    )
  end

  # The skipped count was previously dropped on the floor, so a user who
  # selected 40 groups and saw 12 promoted was told "Accepted 12 group(s)" with
  # no account of the rest. The wording stays generic because a skip covers
  # three distinct causes and the flash has no room to distinguish them; the
  # per-group reason lands on the row as queue_error.
  def queue_message(queued, 0),
    do:
      ngettext("Queued %{count} group for import.", "Queued %{count} groups for import.", queued)

  def queue_message(0, skipped),
    do:
      ngettext(
        "Nothing queued. %{count} group has nothing to import from.",
        "Nothing queued. %{count} groups have nothing to import from.",
        skipped
      )

  def queue_message(queued, skipped),
    do:
      ngettext(
        "Queued %{count} group for import. %{skipped} skipped, nothing to import from.",
        "Queued %{count} groups for import. %{skipped} skipped, nothing to import from.",
        queued,
        skipped: skipped
      )
end
