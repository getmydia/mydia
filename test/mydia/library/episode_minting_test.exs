defmodule Mydia.Library.EpisodeMintingTest do
  @moduledoc """
  End-to-end cover for creating episodes the provider is missing.

  Goes through `FileIngest.ingest/3` rather than calling the enricher directly,
  because the policy is what authorises minting and `FileIngest` owns it.
  """
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures
  import Mydia.MetadataStub
  import Mydia.SettingsFixtures

  alias Mydia.Library
  alias Mydia.Library.FileIngest
  alias Mydia.{Media, MetadataStubProvider, Repo}

  setup :setup_metadata_stub

  setup do
    lp = library_path_fixture(%{type: "series", path: "/media/Series"})
    title = MetadataStubProvider.series_title()
    filename = "#{title} - S01E03 - La chorale.mkv"

    file =
      orphaned_media_file_fixture(%{
        library_path_id: lp.id,
        relative_path: "#{title}/Season 01/#{filename}"
      })

    match = %{
      provider_id: to_string(MetadataStubProvider.series_tvdb_id()),
      provider_type: :tvdb,
      title: title,
      year: nil,
      match_confidence: 1.0,
      from_local_db: true,
      parsed_info: %{
        type: :tv_show,
        season: 1,
        episodes: [3],
        original_filename: filename
      }
    }

    {:ok, library_path: lp, media_file: Repo.preload(file, :library_path), match: match}
  end

  test "an accepted import creates the missing episode and links the file", ctx do
    assert {:linked, item} = FileIngest.ingest(ctx.media_file, ctx.match, policy: :create_items)

    episode = Media.get_episode_by_number(item.id, 1, 3)
    refute is_nil(episode)
    assert episode.title == "La chorale"
    assert is_nil(episode.provider_episode_id)

    assert Library.get_media_file!(ctx.media_file.id).episode_id == episode.id
  end

  test "a scheduled scan leaves the file orphaned with a reason", ctx do
    assert {:error, {:not_associated, message}} =
             FileIngest.ingest(ctx.media_file, ctx.match, policy: :local_only)

    assert message =~ "season 1 episode 3 does not exist"

    reloaded = Library.get_media_file!(ctx.media_file.id)
    assert is_nil(reloaded.episode_id)
    assert is_nil(reloaded.media_item_id)

    assert [%{rank: 0}] = Library.list_match_candidates(ctx.media_file.id)
  end
end
