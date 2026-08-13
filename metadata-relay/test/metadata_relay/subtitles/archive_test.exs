defmodule MetadataRelay.Subtitles.ArchiveTest do
  use ExUnit.Case, async: true

  alias MetadataRelay.Subtitles.Archive

  defp zip(entries) do
    {:ok, {_name, binary}} =
      :zip.create(~c"test.zip", Enum.map(entries, fn {n, c} -> {to_charlist(n), c} end), [:memory])

    binary
  end

  # :zip.create sanitises absolute and parent-relative names, so path-traversal
  # cases must be built by hand. Entry names here are written into the local and
  # central headers exactly as given.
  defp raw_zip(name, content) when is_binary(name) and is_binary(content) do
    local = raw_local_entry(name, content)
    central = raw_central_entry(name, content, 0)

    local <>
      central <>
      <<0x50, 0x4B, 0x05, 0x06, 0::little-16, 0::little-16, 1::little-16, 1::little-16,
        byte_size(central)::little-32, byte_size(local)::little-32, 0::little-16>>
  end

  defp raw_local_entry(name, content) do
    n = byte_size(name)
    c = byte_size(content)
    crc = :erlang.crc32(content)

    <<0x50, 0x4B, 0x03, 0x04, 20::little-16, 0::little-16, 0::little-16, 0::little-16,
      0::little-16, crc::little-32, c::little-32, c::little-32, n::little-16, 0::little-16,
      name::binary, content::binary>>
  end

  defp raw_central_entry(name, content, local_offset) do
    n = byte_size(name)
    c = byte_size(content)
    crc = :erlang.crc32(content)

    <<0x50, 0x4B, 0x01, 0x02, 20::little-16, 20::little-16, 0::little-16, 0::little-16,
      0::little-16, 0::little-16, crc::little-32, c::little-32, c::little-32, n::little-16,
      0::little-16, 0::little-16, 0::little-16, 0::little-16, 0::little-32,
      local_offset::little-32, name::binary>>
  end

  # Build a ZIP where the central directory lies about the uncompressed size,
  # but the local header is correct. This tests check_total_size/1 specifically:
  # check_declared_size/1 reads the central directory (sees the lie, passes),
  # but check_total_size/1 reads the actual expanded content (sees 20MB, fails).
  defp lying_size_zip(name, actual_content, declared_size_in_central)
       when is_binary(name) and is_binary(actual_content) and is_integer(declared_size_in_central) do
    n = byte_size(name)
    c = byte_size(actual_content)
    crc = :erlang.crc32(actual_content)

    # Local header with correct sizes
    local =
      <<0x50, 0x4B, 0x03, 0x04, 20::little-16, 0::little-16, 0::little-16, 0::little-16,
        0::little-16, crc::little-32, c::little-32, c::little-32, n::little-16, 0::little-16,
        name::binary, actual_content::binary>>

    # Central directory with lying uncompressed size, correct compressed size
    central =
      <<0x50, 0x4B, 0x01, 0x02, 20::little-16, 20::little-16, 0::little-16, 0::little-16,
        0::little-16, 0::little-16, crc::little-32, c::little-32,
        declared_size_in_central::little-32, n::little-16, 0::little-16, 0::little-16,
        0::little-16, 0::little-16, 0::little-32, 0::little-32, name::binary>>

    local <>
      central <>
      <<0x50, 0x4B, 0x05, 0x06, 0::little-16, 0::little-16, 1::little-16, 1::little-16,
        byte_size(central)::little-32, byte_size(local)::little-32, 0::little-16>>
  end

  test "extracts the first subtitle entry" do
    archive =
      zip([{"readme.txt", "ignore me"}, {"movie.srt", "1\n00:00:01,000 --> 00:00:02,000\nhi\n"}])

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

  test "rejects an entry escaping via a parent path" do
    binary = raw_zip("../../etc/passwd.srt", "malicious")

    assert {:error, :unsafe_archive_entry} = Archive.extract_subtitle(binary)
  end

  test "rejects an entry with an absolute path" do
    binary = raw_zip("/etc/passwd.srt", "malicious")

    assert {:error, :unsafe_archive_entry} = Archive.extract_subtitle(binary)
  end

  test "rejects an archive that expands beyond the size cap" do
    # A megabyte of zeroes compresses to almost nothing, which is the whole
    # point of a zip bomb: cheap to send, expensive to open.
    binary = zip([{"huge.srt", String.duplicate("0", 20_000_000)}])

    assert {:error, :archive_too_large} = Archive.extract_subtitle(binary)
  end

  test "rejects an archive where declared size lies but actual expands past cap" do
    # Central directory claims only 100 bytes, but the actual uncompressed
    # content is 20MB. This tests check_total_size/1 specifically: the declared
    # size passes check_declared_size/1, but the real expanded size is caught
    # by check_total_size/1 after unzip.
    large_content = String.duplicate("0", 20_000_000)
    binary = lying_size_zip("bomb.srt", large_content, 100)

    assert {:error, :archive_too_large} = Archive.extract_subtitle(binary)
  end
end
