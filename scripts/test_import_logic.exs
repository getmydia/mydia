#!/usr/bin/env elixir
# Test the import logic manually

save_path = "/downloads/complete/【高清剧集网发布 www.DDHDTV.com】布鲁伊 第一季[全52集][国语配音+中文字幕].Bluey.S01.2018.2160p.WEB-DL.H265.AAC-BlackTV"

IO.puts("Testing path: #{save_path}")
IO.puts("Path exists: #{File.exists?(save_path)}")
IO.puts("Is directory: #{File.dir?(save_path)}")

if File.exists?(save_path) and File.dir?(save_path) do
  IO.puts("\nListing files with Path.wildcard...")

  all_files = Path.wildcard(Path.join(save_path, "**/*"))
  IO.puts("Total paths found: #{length(all_files)}")

  regular_files = Enum.filter(all_files, &File.regular?/1)
  IO.puts("Regular files: #{length(regular_files)}")

  files_with_info = Enum.map(regular_files, fn file_path ->
    %{
      path: file_path,
      name: Path.basename(file_path),
      size: File.stat!(file_path).size
    }
  end)

  IO.puts("\nSample files:")
  files_with_info
  |> Enum.take(3)
  |> Enum.each(fn file ->
    IO.puts("  - #{file.name} (#{file.size} bytes)")
  end)

  # Test video filtering
  video_extensions = ~w(.mkv .mp4 .avi .mov .wmv .flv .webm .m4v .mpg .mpeg .m2ts)

  video_files = Enum.filter(files_with_info, fn file ->
    ext = Path.extname(file.name) |> String.downcase()
    ext in video_extensions
  end)

  IO.puts("\nVideo files after filtering: #{length(video_files)}")

  if length(video_files) > 0 do
    IO.puts("\nSample video files:")
    video_files
    |> Enum.take(3)
    |> Enum.each(fn file ->
      ext = Path.extname(file.name)
      IO.puts("  - #{file.name} [ext: #{ext}]")
    end)
  else
    IO.puts("\n⚠️  NO VIDEO FILES FOUND AFTER FILTERING!")
    IO.puts("\nAll file extensions:")
    files_with_info
    |> Enum.map(fn f -> Path.extname(f.name) |> String.downcase() end)
    |> Enum.uniq()
    |> Enum.each(fn ext ->
      count = Enum.count(files_with_info, fn f -> Path.extname(f.name) |> String.downcase() == ext end)
      IO.puts("  #{ext}: #{count} files")
    end)
  end
else
  IO.puts("❌ Path does not exist or is not a directory!")
end
