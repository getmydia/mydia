defmodule Mydia.Library.MediaFileHdrTest do
  use Mydia.DataCase, async: true

  alias Mydia.Library.{Hdr, MediaFile}

  describe "hdr_format enum" do
    test "the schema enum matches Hdr.bases/0 exactly" do
      # These two lists are declared separately so MediaFile carries no
      # compile-time dependency on Hdr. This test is what keeps them honest.
      assert Ecto.Enum.values(MediaFile, :hdr_format) == Hdr.bases()
    end

    test "accepts every canonical base" do
      for base <- Hdr.bases() do
        changeset = MediaFile.changeset(%MediaFile{}, %{hdr_format: base})
        assert changeset.errors[:hdr_format] == nil, "rejected #{base}"
      end
    end

    test "rejects a legacy display string" do
      changeset = MediaFile.changeset(%MediaFile{}, %{hdr_format: "Dolby Vision"})
      assert changeset.errors[:hdr_format] != nil
    end
  end

  describe "dolby vision columns" do
    test "cast and persist" do
      changeset =
        MediaFile.changeset(%MediaFile{}, %{
          dolby_vision_profile: 8,
          dolby_vision_bl_compat_id: 1
        })

      assert Ecto.Changeset.get_field(changeset, :dolby_vision_profile) == 8
      assert Ecto.Changeset.get_field(changeset, :dolby_vision_bl_compat_id) == 1
    end
  end
end
