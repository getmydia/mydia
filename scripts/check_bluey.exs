#!/usr/bin/env elixir
# Script to check Bluey Season 1 status
import Ecto.Query
alias Mydia.Repo
alias Mydia.Media.{MediaItem, Episode}
alias Mydia.Downloads.Download
alias Mydia.Library.MediaFile

# Find Bluey show (SQLite uses LIKE for case-insensitive by default)
bluey = Repo.one(from m in MediaItem, where: like(m.title, "%Bluey%") or like(m.title, "%bluey%"))

if bluey do
  IO.puts("\n=== Bluey Show ===")
  IO.puts("Title: #{bluey.title}")
  IO.puts("Type: #{bluey.type}")
  IO.puts("Monitored: #{bluey.monitored}")
  IO.puts("ID: #{bluey.id}")

  # Get Season 1 episodes
  IO.puts("\n=== Season 1 Episodes Status ===")
  episodes = Repo.all(
    from e in Episode,
    where: e.media_item_id == ^bluey.id and e.season_number == 1,
    order_by: [asc: e.episode_number],
    preload: [:media_files, :downloads]
  )

  IO.puts("Total S01 episodes: #{length(episodes)}")

  # Count by status
  with_files = Enum.count(episodes, fn e -> length(e.media_files) > 0 end)
  with_downloads = Enum.count(episodes, fn e -> length(e.downloads) > 0 end)

  IO.puts("Episodes with media files: #{with_files}")
  IO.puts("Episodes with active downloads: #{with_downloads}")

  # Check for completed downloads that are still in DB
  IO.puts("\n=== Checking for Download Records (Should Be Empty After Import) ===")
  downloads = Repo.all(
    from d in Download,
    where: d.media_item_id == ^bluey.id,
    order_by: [desc: d.inserted_at]
  )

  IO.puts("Total download records: #{length(downloads)}")

  if length(downloads) > 0 do
    completed = Enum.filter(downloads, fn d -> not is_nil(d.completed_at) end)
    IO.puts("Completed downloads (SHOULD HAVE BEEN DELETED): #{length(completed)}")

    if length(completed) > 0 do
      IO.puts("\n⚠️  PROBLEM FOUND: These downloads are marked completed but not imported/deleted:")
      Enum.each(completed, fn d ->
        ep = if d.episode_id do
          Repo.get(Episode, d.episode_id)
        else
          nil
        end

        ep_str = if ep do
          "S#{String.pad_leading(to_string(ep.season_number), 2, "0")}E#{String.pad_leading(to_string(ep.episode_number), 2, "0")}"
        else
          "N/A"
        end

        IO.puts("\n  Download ID: #{d.id}")
        IO.puts("  Title: #{d.title}")
        IO.puts("  Episode: #{ep_str}")
        IO.puts("  Completed: #{d.completed_at}")
        IO.puts("  Client: #{d.download_client} / #{d.download_client_id}")
        IO.puts("  Error: #{inspect(d.error_message)}")
      end)
    end

    active = Enum.filter(downloads, fn d -> is_nil(d.completed_at) and is_nil(d.error_message) end)
    if length(active) > 0 do
      IO.puts("\n=== Active Downloads (In Progress) ===")
      Enum.each(active, fn d ->
        IO.puts("  - #{d.title}")
      end)
    end
  end

  # Check Oban jobs for MediaImport
  IO.puts("\n=== Checking Oban MediaImport Jobs ===")

  failed_jobs = Repo.all(
    from j in "oban_jobs",
    where: j.worker == "Mydia.Jobs.MediaImport" and j.state != "completed",
    select: %{
      id: j.id,
      state: j.state,
      errors: j.errors,
      args: j.args,
      inserted_at: j.inserted_at
    },
    order_by: [desc: j.inserted_at],
    limit: 10
  )

  if length(failed_jobs) > 0 do
    IO.puts("Found #{length(failed_jobs)} non-completed MediaImport jobs:")
    Enum.each(failed_jobs, fn job ->
      IO.puts("\n  Job ID: #{job.id}")
      IO.puts("  State: #{job.state}")
      IO.puts("  Download ID: #{get_in(job.args, ["download_id"])}")
      IO.puts("  Inserted: #{job.inserted_at}")

      if job.errors && length(job.errors) > 0 do
        error = List.first(job.errors)
        IO.puts("  Error: #{get_in(error, ["error"])}")
      end
    end)
  else
    IO.puts("No failed/pending MediaImport jobs found")
  end

  # Show media files found
  IO.puts("\n=== Media Files for Season 1 ===")
  files = Repo.all(
    from mf in MediaFile,
    join: e in Episode, on: mf.episode_id == e.id,
    where: e.media_item_id == ^bluey.id and e.season_number == 1,
    order_by: [asc: e.episode_number],
    preload: [episode: e]
  )

  IO.puts("Total media files imported: #{length(files)}")

  if length(files) > 0 do
    IO.puts("\nSample files (first 5):")
    files
    |> Enum.take(5)
    |> Enum.each(fn f ->
      ep = f.episode
      IO.puts("  S#{String.pad_leading(to_string(ep.season_number), 2, "0")}E#{String.pad_leading(to_string(ep.episode_number), 2, "0")} - #{Path.basename(f.path)}")
    end)
  end
else
  IO.puts("❌ Bluey show not found in database")
end

IO.puts("\n")
