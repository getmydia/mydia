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

  test "an accepted import takes the fast path when episodes already exist and still mints",
       ctx do
    title = MetadataStubProvider.series_title()

    # Bootstrap the show through an ordinary first import, so it already has
    # episodes before the S01E03 file below is ever ingested -- this is the
    # production trigger: TVDB 447978 already had three published seasons
    # when the season 4 files landed. `MetadataEnricher.enrich/2` only takes
    # the fast path (`associate_file_with_target_episodes/3` directly) when
    # `episodes_exist_for_show?/1` is already true at that moment, which the
    # two other tests in this file never exercise -- both start from a show
    # with no episodes at all and so only ever take the slow path
    # (`enrich_episodes/5`).
    bootstrap_filename = "#{title} - S01E01 - Pilot.mkv"

    bootstrap_file =
      orphaned_media_file_fixture(%{
        library_path_id: ctx.library_path.id,
        relative_path: "#{title}/Season 01/#{bootstrap_filename}"
      })

    bootstrap_match = %{
      ctx.match
      | parsed_info: %{
          type: :tv_show,
          season: 1,
          episodes: [1],
          original_filename: bootstrap_filename
        }
    }

    assert {:linked, show} =
             FileIngest.ingest(bootstrap_file, bootstrap_match, policy: :create_items)

    # The stub's catalog carries two seasons, so the bootstrap's slow-path
    # `enrich_episodes/5` fetched and upserted both: max season 2, max
    # episode 2. This also confirms the S01E03 coordinate below is a
    # plausible mint target: season 1 <= max_season(2) + 1, episode 3 <=
    # max(2 + 10, 30).
    assert Media.episode_bounds(show.id) == {2, 2}

    # Poison the bootstrapped S01E01 row with a title the SLOW path's
    # `upsert_episodes_from_season/3` would overwrite on its way through --
    # it always writes `title: episode.name`, and the stub always answers
    # "Stub Episode One" for season 1 episode 1 -- but that the FAST path's
    # direct `Media.get_episode_by_number/3` lookup in
    # `associate_file_with_target_episodes/3` never touches. Its survival
    # below is the proof this test actually took the fast path rather than
    # merely reaching the same end state by a different route.
    s1e1 = Media.get_episode_by_number(show.id, 1, 1)
    {:ok, _} = Media.update_episode(s1e1, %{title: "FAST-PATH-MARKER"})

    assert {:linked, item} = FileIngest.ingest(ctx.media_file, ctx.match, policy: :create_items)
    assert item.id == show.id

    # The marker survived: enrich_episodes/5 (and its season re-fetch/upsert)
    # never ran for this second ingest.
    assert Media.get_episode_by_number(show.id, 1, 1).title == "FAST-PATH-MARKER"

    episode = Media.get_episode_by_number(item.id, 1, 3)
    refute is_nil(episode)
    assert episode.title == "La chorale"
    assert is_nil(episode.provider_episode_id)

    assert Library.get_media_file!(ctx.media_file.id).episode_id == episode.id
  end
end
