#!/usr/bin/env elixir
# Final verification of Bluey import

import Ecto.Query
alias Mydia.Repo
alias Mydia.Media.{MediaItem, Episode}
alias Mydia.Library.MediaFile

# Find Bluey
bluey = Repo.one(from m in MediaItem, where: like(m.title, "%Bluey%"))

if bluey do
  # Get Season 1 episodes with files
  episodes = Repo.all(
    from e in Episode,
    where: e.media_item_id == ^bluey.id and e.season_number == 1,
    preload: [:media_files],
    order_by: [asc: e.episode_number]
  )

  total_episodes = length(episodes)
  episodes_with_files = Enum.count(episodes, fn e -> length(e.media_files) > 0 end)
  episodes_without_files = total_episodes - episodes_with_files

  IO.puts("=== Bluey Season 1 Import Verification ===")
  IO.puts("\nTotal Episodes: #{total_episodes}")
  IO.puts("Episodes with files: #{episodes_with_files}")
  IO.puts("Episodes without files: #{episodes_without_files}")

  if episodes_without_files > 0 do
    IO.puts("\n⚠️  Missing files for:")
    episodes
    |> Enum.filter(fn e -> length(e.media_files) == 0 end)
    |> Enum.each(fn e ->
      IO.puts("  S#{String.pad_leading(to_string(e.season_number), 2, "0")}E#{String.pad_leading(to_string(e.episode_number), 2, "0")} - #{e.title}")
    end)
  end

  # Show sample imported files
  sample_files = episodes
    |> Enum.filter(fn e -> length(e.media_files) > 0 end)
    |> Enum.take(5)

  IO.puts("\n=== Sample Imported Files ===")
  Enum.each(sample_files, fn e ->
    file = List.first(e.media_files)
    IO.puts("S#{String.pad_leading(to_string(e.season_number), 2, "0")}E#{String.pad_leading(to_string(e.episode_number), 2, "0")} - #{e.title}")
    IO.puts("  File: #{Path.basename(file.path)}")
    IO.puts("  Resolution: #{file.resolution}")
    IO.puts("  Size: #{Float.round(file.size / 1_000_000, 1)} MB")
  end)

  if episodes_without_files == 0 do
    IO.puts("\n✓ ALL SEASON 1 EPISODES SUCCESSFULLY IMPORTED!")
  end
else
  IO.puts("Bluey not found")
end
