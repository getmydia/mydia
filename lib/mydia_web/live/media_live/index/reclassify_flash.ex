defmodule MydiaWeb.MediaLive.Index.ReclassifyFlash do
  @moduledoc """
  The flash message for the library's bulk reclassify action.
  """
  use Gettext, backend: MydiaWeb.Gettext

  @spec message(%{
          required(:updated) => non_neg_integer(),
          required(:skipped) => non_neg_integer(),
          optional(atom()) => term()
        }) :: String.t()
  def message(%{updated: updated, skipped: skipped}) when updated > 0 and skipped > 0,
    do:
      ngettext(
        "Reclassified %{count} item, %{skipped} skipped (category override)",
        "Reclassified %{count} items, %{skipped} skipped (category override)",
        updated,
        skipped: skipped
      )

  def message(%{updated: updated}) when updated > 0,
    do: ngettext("Reclassified %{count} item", "Reclassified %{count} items", updated)

  def message(%{skipped: skipped}) when skipped > 0,
    do:
      ngettext(
        "No changes - %{count} item has category override",
        "No changes - %{count} items have category override",
        skipped
      )

  def message(_summary), do: gettext("No category changes detected")
end
