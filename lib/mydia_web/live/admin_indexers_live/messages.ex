defmodule MydiaWeb.AdminIndexersLive.Messages do
  @moduledoc """
  Flash text for the Indexers page, kept out of `AdminIndexersLive.Index` so
  that large module does not grow with its translations.
  """

  use Gettext, backend: MydiaWeb.Gettext

  @spec sync_completed(%{created: integer(), updated: integer(), failed: integer()}) ::
          String.t()
  def sync_completed(stats) do
    gettext("Sync completed: %{created} created, %{updated} updated, %{failed} failed",
      created: stats.created,
      updated: stats.updated,
      failed: stats.failed
    )
  end

  @spec library_flaresolverr_toggled(boolean(), String.t()) :: String.t()
  def library_flaresolverr_toggled(true, name),
    do: gettext("FlareSolverr enabled for %{name}", name: name)

  def library_flaresolverr_toggled(false, name),
    do: gettext("FlareSolverr disabled for %{name}", name: name)

  @spec library_indexer_toggled(boolean(), String.t()) :: String.t()
  def library_indexer_toggled(true, name), do: gettext("%{name} enabled", name: name)
  def library_indexer_toggled(false, name), do: gettext("%{name} disabled", name: name)

  @spec runtime_indexer_read_only() :: String.t()
  def runtime_indexer_read_only do
    gettext(
      "Cannot delete runtime-configured indexer. This indexer is configured via environment variables and is read-only in the UI."
    )
  end
end
