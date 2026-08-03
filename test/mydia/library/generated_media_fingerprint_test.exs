defmodule Mydia.Library.GeneratedMediaFingerprintTest do
  use ExUnit.Case, async: false

  alias Mydia.Library.GeneratedMedia

  @content "1234567,2345678,3456789"

  setup do
    # System.unique_integer/1 is collision-free within the VM, unlike
    # :rand.uniform/1, so a leftover directory from an earlier run or a
    # concurrent test cannot collide with this one.
    test_dir =
      Path.join([
        System.tmp_dir!(),
        "generated_media_fingerprint_test_#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(test_dir)

    Application.put_env(:mydia, :generated_media_path, test_dir)

    on_exit(fn ->
      File.rm_rf!(test_dir)
      Application.delete_env(:mydia, :generated_media_path)
    end)

    {:ok, test_dir: test_dir}
  end

  test "stores and reads back a fingerprint" do
    assert {:ok, checksum} = GeneratedMedia.store(:fingerprint, @content)
    assert GeneratedMedia.exists?(:fingerprint, checksum)

    path = GeneratedMedia.get_path(:fingerprint, checksum)
    assert Path.extname(path) == ".fpr"
    assert File.read!(path) == @content

    assert :ok = GeneratedMedia.delete(:fingerprint, checksum)
    refute GeneratedMedia.exists?(:fingerprint, checksum)
  end

  test "identical content deduplicates to one checksum" do
    assert {:ok, a} = GeneratedMedia.store(:fingerprint, @content)
    assert {:ok, b} = GeneratedMedia.store(:fingerprint, @content)
    assert a == b

    GeneratedMedia.delete(:fingerprint, a)
  end

  test "stores a fingerprint from a file on disk", %{test_dir: test_dir} do
    source_path = Path.join(test_dir, "source.fpr")
    File.write!(source_path, @content)

    assert {:ok, checksum} = GeneratedMedia.store_file(:fingerprint, source_path)
    assert GeneratedMedia.exists?(:fingerprint, checksum)
    assert File.read!(GeneratedMedia.get_path(:fingerprint, checksum)) == @content
  end

  test "builds a url path for a fingerprint" do
    checksum = "abc123def456789012345678901234ab"

    assert GeneratedMedia.url_path(:fingerprint, checksum) ==
             "/generated/fingerprints/ab/c1/#{checksum}.fpr"
  end

  test "fingerprints are stored under their own directory", %{test_dir: test_dir} do
    {:ok, checksum} = GeneratedMedia.store(:fingerprint, @content)

    expected_path =
      Path.join([
        test_dir,
        "fingerprints",
        String.slice(checksum, 0, 2),
        String.slice(checksum, 2, 2),
        "#{checksum}.fpr"
      ])

    assert File.exists?(expected_path)
  end
end
