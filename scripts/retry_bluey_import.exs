#!/usr/bin/env elixir
# Script to retry importing Bluey Season 1

import Ecto.Query
alias Mydia.Repo
alias Mydia.Downloads.Download

# Find the completed Bluey download
download = Repo.one(
  from d in Download,
  join: mi in assoc(d, :media_item),
  where: like(mi.title, "%Bluey%") and not is_nil(d.completed_at),
  limit: 1
)

if download do
  IO.puts("Found completed Bluey download:")
  IO.puts("  ID: #{download.id}")
  IO.puts("  Title: #{download.title}")
  IO.puts("  Completed: #{download.completed_at}")
  IO.puts("  Client: #{download.download_client}")
  IO.puts("  Client ID: #{download.download_client_id}")

  # Get the save_path from Transmission or construct it
  save_path = "/downloads/complete/【高清剧集网发布 www.DDHDTV.com】布鲁伊 第一季[全52集][国语配音+中文字幕].Bluey.S01.2018.2160p.WEB-DL.H265.AAC-BlackTV"

  IO.puts("\n  Save path: #{save_path}")

  # Create a new MediaImport job
  IO.puts("\nCreating new MediaImport job...")

  job_args = %{
    "download_id" => download.id,
    "save_path" => save_path,
    "cleanup_client" => false,  # Don't try to remove from client since it's already gone
    "use_hardlinks" => true
  }

  case Mydia.Jobs.MediaImport.new(job_args) |> Oban.insert() do
    {:ok, job} ->
      IO.puts("✓ MediaImport job created successfully!")
      IO.puts("  Job ID: #{job.id}")
      IO.puts("  State: #{job.state}")
      IO.puts("\nThe import should start within a few seconds...")
      IO.puts("Monitor progress with: ./dev logs -f | grep -i import")

    {:error, changeset} ->
      IO.puts("✗ Failed to create job:")
      IO.inspect(changeset.errors)
  end
else
  IO.puts("No completed Bluey download found")
end
