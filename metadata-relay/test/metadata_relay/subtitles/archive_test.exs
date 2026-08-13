defmodule MetadataRelay.Subtitles.ArchiveTest do
  use ExUnit.Case, async: true

  alias MetadataRelay.Subtitles.Archive

  defp zip(entries) do
    {:ok, {_name, binary}} =
      :zip.create(~c"test.zip", Enum.map(entries, fn {n, c} -> {to_charlist(n), c} end), [:memory])

    binary
  end

  test "extracts the first subtitle entry" do
    archive = zip([{"readme.txt", "ignore me"}, {"movie.srt", "1\n00:00:01,000 --> 00:00:02,000\nhi\n"}])

    assert {:ok, %{name: "movie.srt", content: content}} = Archive.extract_subtitle(archive)
    assert content =~ "hi"
  end

  test "reports an archive holding no subtitle" do
    archive = zip([{"readme.txt", "nothing here"}])

    assert {:error, :no_subtitle_in_archive} = Archive.extract_subtitle(archive)
  end

  test "rejects a non-archive" do
    assert {:error, :invalid_archive} = Archive.extract_subtitle("not a zip at all")
  end

  test "recognises the zip magic" do
    assert Archive.zip?(zip([{"a.srt", "x"}]))
    refute Archive.zip?("plain text")
  end
end
