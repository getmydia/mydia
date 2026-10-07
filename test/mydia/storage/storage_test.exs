defmodule Mydia.StorageTest do
  use Mydia.DataCase, async: false

  alias Mydia.Library.MediaFile
  alias Mydia.Settings.LibraryPath
  alias Mydia.Storage
  alias Mydia.Storage.Error

  @moduletag :tmp_dir

  describe "redact_text/1" do
    test "strips the query from every URL in a string" do
      text = "a http://h/x?X-Amz-Signature=abc and https://h2/y/z?k=v&X-Amz-Credential=q done"

      assert Storage.redact_text(text) == "a http://h/x and https://h2/y/z done"
    end

    test "handles a URL at the end of the string" do
      assert Storage.redact_text("Opening http://h/x?X-Amz-Signature=abc") ==
               "Opening http://h/x"
    end

    test "handles single and double quoted URLs" do
      assert Storage.redact_text("from 'http://h/x?X-Amz-Signature=abc': bad") ==
               "from 'http://h/x': bad"

      assert Storage.redact_text(~s(url="https://h/x?X-Amz-Signature=abc" next)) ==
               ~s(url="https://h/x" next)
    end

    test "leaves text without URL queries unchanged" do
      assert Storage.redact_text("plain /tmp/a?b and http://h/x") ==
               "plain /tmp/a?b and http://h/x"
    end

    test "inspects non-binary terms first" do
      assert Storage.redact_text({:error, "http://h/x?X-Amz-Signature=abc"}) ==
               ~s({:error, "http://h/x"})
    end
  end

  test "source/1 and media_input/1 for a local file", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "a.mkv"), "x")
    mf = %MediaFile{relative_path: "a.mkv", library_path: %LibraryPath{path: dir}}

    assert {:ok, %{path: path}} = Storage.source(mf)
    assert path == Path.join(dir, "a.mkv")
    assert {:ok, ^path} = Storage.media_input(mf)

    assert {:error, %Error{kind: :not_found}} =
             Storage.media_input(%{mf | relative_path: "gone.mkv"})
  end

  test "an unknown backend or malformed S3 path is :misconfigured, never :not_found" do
    assert {:error, %Error{kind: :misconfigured}} =
             Storage.location(%LibraryPath{path: "s3://nobody/movies"})

    assert {:error, %Error{kind: :misconfigured}} = Storage.location(%LibraryPath{path: "s3://"})
  end

  test "an unloaded library_path is an error, not a crash" do
    mf = %MediaFile{relative_path: "a.mkv", library_path: %Ecto.Association.NotLoaded{}}
    assert {:error, %Error{}} = Storage.source(mf)
  end

  test "absolute_path/1 is nil for S3 files" do
    mf = %MediaFile{relative_path: "a.mkv", library_path: %LibraryPath{path: "s3://media/m"}}
    assert MediaFile.absolute_path(mf) == nil
  end

  test "ensure_writable/1" do
    assert :ok = Storage.ensure_writable(%LibraryPath{path: "/data"})

    assert {:error, %Error{kind: :read_only}} =
             Storage.ensure_writable(%LibraryPath{path: "s3://m/x"})

    assert {:error, %Error{kind: :read_only}} = Storage.ensure_writable("s3://m/x/file.mkv")
    assert :ok = Storage.ensure_writable(nil)
  end
end
