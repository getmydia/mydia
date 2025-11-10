#!/usr/bin/env elixir
# Check if Bluey import succeeded

import Ecto.Query
alias Mydia.Repo
alias Mydia.Media.{MediaItem, Episode}
alias Mydia.Library.MediaFile
alias Mydia.Downloads.Download

# Find Bluey show
bluey = Repo.one(from m in MediaItem, where: like(m.title, "%Bluey%") or like(m.title, "%bluey%"))

if bluey do
  # Count Season 1 episodes with files
  episodes_with_files = Repo.one(
    from e in Episode,
    left_join: mf in MediaFile, on: mf.episode_id == e.id,
    where: e.media_item_id == ^bluey.id and e.season_number == 1,
    select: count(distinct e.id, :filter, not is_nil(mf.id))
  )

  total_files = Repo.one(
    from mf in MediaFile,
    join: e in Episode, on: mf.episode_id == e.id,
    where: e.media_item_id == ^bluey.id and e.season_number == 1,
    select: count(mf.id)
  )

  downloads_count = Repo.one(
    from d in Download,
    where: d.media_item_id == ^bluey.id,
    select: count(d.id)
  )

  IO.puts("\n=== Bluey Season 1 Import Status ===")
  IO.puts("Episodes with files: #{episodes_with_files} / 52")
  IO.puts("Total media files: #{total_files}")
  IO.puts("Remaining downloads: #{downloads_count}")

  if episodes_with_files == 52 and downloads_count == 0 do
    IO.puts("\n✓ SUCCESS! All Season 1 episodes imported!")
  elsif episodes_with_files > 0 do
    IO.puts("\n⚠️  PARTIAL: Some episodes imported, but not all")
  else
    IO.puts("\n✗ FAILED: No episodes imported yet")
  end

  # Check latest Oban job
  latest_job = Repo.one(
    from j in "oban_jobs",
    where: j.worker == "Mydia.Jobs.MediaImport",
    order_by: [desc: j.id],
    select: %{id: j.id, state: j.state, errors: j.errors},
    limit: 1
  )

  if latest_job do
    IO.puts("\nLatest MediaImport job:")
    IO.puts("  ID: #{latest_job.id}")
    IO.puts("  State: #{latest_job.state}")

    if latest_job.errors && length(latest_job.errors) > 0 do
      IO.puts("  Last error: #{inspect(List.first(latest_job.errors))}")
    end
  end
else
  IO.puts("Bluey show not found")
end
