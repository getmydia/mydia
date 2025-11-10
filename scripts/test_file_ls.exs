#!/usr/bin/env elixir
# Test File.ls! with Unicode path

save_path = "/downloads/complete/【高清剧集网发布 www.DDHDTV.com】布鲁伊 第一季[全52集][国语配音+中文字幕].Bluey.S01.2018.2160p.WEB-DL.H265.AAC-BlackTV"

IO.puts("Testing File.ls! with Unicode path...")
IO.puts("Path: #{save_path}")

defmodule FileHelper do
  def list_files_recursive(dir) do
    try do
      File.ls!(dir)
      |> Enum.flat_map(fn entry ->
        full_path = Path.join(dir, entry)

        cond do
          File.regular?(full_path) ->
            [%{
              path: full_path,
              name: Path.basename(full_path),
              size: File.stat!(full_path).size
            }]

          File.dir?(full_path) ->
            list_files_recursive(full_path)

          true ->
            []
        end
      end)
    rescue
      e ->
        IO.puts("Error: #{Exception.message(e)}")
        []
    end
  end
end

files = FileHelper.list_files_recursive(save_path)
IO.puts("\nTotal files found: #{length(files)}")

# Filter video files
video_extensions = ~w(.mkv .mp4 .avi .mov .wmv .flv .webm .m4v .mpg .mpeg .m2ts)

video_files = Enum.filter(files, fn file ->
  ext = Path.extname(file.name) |> String.downcase()
  ext in video_extensions
end)

IO.puts("Video files: #{length(video_files)}")

if length(video_files) > 0 do
  IO.puts("\nSample video files:")
  video_files
  |> Enum.take(5)
  |> Enum.each(fn file ->
    IO.puts("  - #{file.name}")
  end)

  IO.puts("\n✓ SUCCESS! Files can be listed with File.ls!")
else
  IO.puts("\n✗ FAILED! No video files found")
end
