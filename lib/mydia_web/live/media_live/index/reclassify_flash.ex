defmodule MydiaWeb.MediaLive.Index.ReclassifyFlash do
  @moduledoc """
  The flash message for the library's bulk reclassify action.
  """

  @spec message(%{
          required(:updated) => non_neg_integer(),
          required(:skipped) => non_neg_integer(),
          optional(atom()) => term()
        }) :: String.t()
  def message(%{updated: updated, skipped: skipped}) when updated > 0 and skipped > 0,
    do: "Reclassified #{updated} #{items(updated)}, #{skipped} skipped (category override)"

  def message(%{updated: updated}) when updated > 0,
    do: "Reclassified #{updated} #{items(updated)}"

  def message(%{skipped: skipped}) when skipped > 0,
    do: "No changes - #{skipped} #{items(skipped)} #{verb(skipped)} category override"

  def message(_summary), do: "No category changes detected"

  defp verb(1), do: "has"
  defp verb(_), do: "have"

  defp items(1), do: "item"
  defp items(_), do: "items"
end
