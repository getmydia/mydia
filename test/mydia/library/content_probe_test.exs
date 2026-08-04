defmodule Mydia.Library.ContentProbeTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.ContentProbe

  @moduletag :tmp_dir

  test "reports not_media for a file ffprobe cannot parse", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "fake.exe")
    File.write!(path, "MZ" <> :binary.copy(<<0>>, 4096))

    assert %{"status" => "not_media", "detail" => detail} = ContentProbe.probe(path)
    assert is_binary(detail)
  end

  test "reports unknown for a file that does not exist", %{tmp_dir: tmp_dir} do
    assert %{"status" => "unknown"} = ContentProbe.probe(Path.join(tmp_dir, "gone.mkv"))
  end
end
