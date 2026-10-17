defmodule Mydia.Repo.Migrations.BackfillEac3AudioCodec do
  use Ecto.Migration
  import Ecto.Query

  @moduledoc """
  Relabels Dolby Digital Plus files that were stored as `audio_codec = "ac3"`.

  `Mydia.Streaming.Codec.normalize_audio_codec/1` checked its AC3 pattern
  before E-AC3, and that pattern's `\\bdd` matched the analyzer's "DD+ 5.1", so
  every E-AC3 file landed in the column as "ac3". The analyzer's own string
  survives in `metadata.audio_codec_raw`, which tells the two apart.

  `metadata` is Jason-encoded TEXT on both adapters, and Jason writes no
  whitespace and leaves "+" unescaped, so a LIKE match is portable. The
  underscores in the key are LIKE wildcards, which only widen the match to
  strings that are not there.

  Files analyzed before `audio_codec_raw` existed have nothing to read and stay
  "ac3" until they are next analyzed.
  """

  def up, do: backfill()

  # The rows this rewrote were mislabeled; there is nothing worth restoring.
  def down, do: :ok

  @doc false
  def backfill do
    from(f in "media_files",
      where: f.audio_codec == "ac3" and like(f.metadata, ~s(%"audio_codec_raw":"DD+%))
    )
    |> query_repo().update_all(set: [audio_codec: "eac3"])
  end

  # `repo/0` from Ecto.Migration only works inside a migration runner. Tests
  # call `backfill/0` directly, so fall back to Mydia.Repo outside that context.
  defp query_repo do
    case Process.get(:ecto_migration) do
      %{runner: _} -> repo()
      _ -> Mydia.Repo
    end
  end
end
