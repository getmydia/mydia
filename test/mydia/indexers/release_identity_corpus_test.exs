defmodule Mydia.Indexers.ReleaseIdentityCorpusTest do
  @moduledoc """
  Pins ReleaseIdentity's verdict on one fictional stand-in for every pattern
  production grab history surfaced, including the accepted losses. A change
  that flips any row has to update the fixture on purpose.
  """
  use ExUnit.Case, async: true

  alias Mydia.Indexers.ReleaseIdentity
  alias Mydia.Indexers.ReleaseIdentity.Target
  alias Mydia.Media.MediaItem
  alias Mydia.Metadata.Structs.MediaMetadata

  @corpus_path Path.expand("../../fixtures/release_identity/corpus.exs", __DIR__)
  @external_resource @corpus_path
  {corpus, _bindings} = Code.eval_file(@corpus_path)

  for row <- corpus do
    @row Map.put_new(row, :alt_titles, [])
    test "#{row.note}: #{row.release}" do
      item = %MediaItem{
        type: Atom.to_string(@row.type),
        title: @row.title,
        year: @row.year,
        metadata: %MediaMetadata{
          provider_id: "1",
          provider: :tmdb,
          media_type: @row.type,
          alternative_titles: @row.alt_titles
        }
      }

      assert ReleaseIdentity.check(@row.release, Target.from_media_item(item)) == @row.expect
    end
  end
end
