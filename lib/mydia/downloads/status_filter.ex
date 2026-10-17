defmodule Mydia.Downloads.StatusFilter do
  @moduledoc """
  In-memory status filters for enriched download lists.

  `filter/2` takes a list of downloads and one of these filter atoms:

    * `:all` - every download
    * `:active` - not yet imported and downloading, seeding, checking, paused,
      queued or grabbing
    * `:completed` - the client reports the download as completed
    * `:imported` - successfully imported to the library (the Downloads tab's Imported view)
    * `:failed` - failed in the client or failed to import, excluding
      unresolved files
    * `:unresolved_files` - files that could not be matched
  """

  @spec filter(list(), atom()) :: list()
  def filter(downloads, :all), do: downloads

  def filter(downloads, :active) do
    Enum.filter(downloads, fn d ->
      # Active downloads are those that haven't been imported yet
      # and are currently downloading, seeding, checking, paused, or queued.
      # `queued` covers the debrid lifecycle phases where the provider is
      # waiting on the swarm or Mydia's local fetcher hasn't claimed the
      # ready job yet — without this they'd vanish from the queue tab.
      is_nil(d.imported_at) and
        d.status in ["downloading", "seeding", "checking", "paused", "queued", "grabbing"]
    end)
  end

  def filter(downloads, :completed) do
    Enum.filter(downloads, &(&1.status == "completed"))
  end

  # Filter for imported downloads (shown in the Downloads tab's Imported view)
  # These are downloads that have been successfully imported to the library
  # but may still be seeding in the download client
  def filter(downloads, :imported) do
    Enum.filter(downloads, fn d ->
      not is_nil(d.imported_at)
    end)
  end

  def filter(downloads, :failed) do
    Enum.filter(downloads, fn d ->
      # Show downloads that failed in the client OR have import failures.
      # Exclude unresolved_files, which has its own section.
      (d.status in ["failed", "missing"] || not is_nil(d.import_failed_at)) and
        d.match_status != "unresolved_files"
    end)
  end

  def filter(downloads, :unresolved_files) do
    Enum.filter(downloads, fn d ->
      d.match_status == "unresolved_files"
    end)
  end
end
