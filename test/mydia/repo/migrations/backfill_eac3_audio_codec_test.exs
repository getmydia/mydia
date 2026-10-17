defmodule Mydia.Repo.Migrations.BackfillEac3AudioCodecTest do
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures

  alias Mydia.Library.MediaFile
  alias Mydia.Library.Structs.FileMetadata

  # Migration modules are not compiled into the app, so load the file before
  # referencing it. Guarded because the `test` alias may already have defined
  # the module while migrating this VM's database.
  unless Code.ensure_loaded?(Mydia.Repo.Migrations.BackfillEac3AudioCodec) do
    Code.require_file("priv/repo/migrations/20261017144407_backfill_eac3_audio_codec.exs")
  end

  alias Mydia.Repo.Migrations.BackfillEac3AudioCodec

  defp file_with(audio_codec, raw) do
    file = media_file_fixture()

    file
    |> Ecto.Changeset.change(
      audio_codec: audio_codec,
      metadata: %FileMetadata{FileMetadata.empty() | audio_codec_raw: raw}
    )
    |> Repo.update!()
  end

  defp reload(file), do: Repo.get!(MediaFile, file.id).audio_codec

  test "relabels a DD+ file the normalizer stored as ac3" do
    file = file_with("ac3", "DD+ 5.1")

    BackfillEac3AudioCodec.backfill()

    assert reload(file) == "eac3"
  end

  test "leaves a genuine AC3 file alone" do
    file = file_with("ac3", "AC3 5.1")

    BackfillEac3AudioCodec.backfill()

    assert reload(file) == "ac3"
  end

  test "leaves a legacy ac3 row with no raw string alone" do
    file = file_with("ac3", nil)

    BackfillEac3AudioCodec.backfill()

    assert reload(file) == "ac3"
  end
end
