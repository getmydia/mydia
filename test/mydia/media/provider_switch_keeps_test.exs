defmodule Mydia.Media.ProviderSwitchKeepsTest do
  @moduledoc """
  A provider switch deletes and recreates every episode, so Smart Space
  episode keeps would cascade away. They become season keeps instead.
  """
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures
  import Mydia.MetadataStub

  alias Mydia.Accounts.Scope
  alias Mydia.Media.{MediaItem, ProviderSwitch}
  alias Mydia.MetadataStubProvider
  alias Mydia.Repo
  alias Mydia.SmartSpace.{Keep, Rules}

  setup :setup_metadata_stub

  test "episode keeps survive as season keeps, without duplicating a season keep" do
    library = library_path_fixture(%{type: "series", tv_metadata_source: :tvdb})

    item =
      media_item_fixture(%{
        type: "tv_show",
        title: "Lantern Harbor",
        tvdb_id: 70_201,
        metadata_source: :tvdb
      })

    s2e3 = episode_fixture(%{media_item_id: item.id, season_number: 2, episode_number: 3})
    s2e4 = episode_fixture(%{media_item_id: item.id, season_number: 2, episode_number: 4})
    s3e1 = episode_fixture(%{media_item_id: item.id, season_number: 3, episode_number: 1})
    media_file_fixture(%{episode_id: s2e3.id, library_path_id: library.id})

    for ep <- [s2e3, s2e4, s3e1], do: {:ok, _} = Rules.keep({:episode, item.id, ep.id}, nil)
    {:ok, _} = Rules.keep({:season, item.id, 3}, nil)

    candidate = %{provider_id: MetadataStubProvider.series_tmdb_id(), provider: :tmdb}

    assert {:ok, _updated} =
             ProviderSwitch.adopt_provider_switch(
               Scope.system(),
               Repo.get!(MediaItem, item.id),
               candidate,
               :tmdb
             )

    keeps = Repo.all(from k in Keep, where: k.media_item_id == ^item.id)
    assert Enum.all?(keeps, &is_nil(&1.episode_id))
    assert keeps |> Enum.map(& &1.season_number) |> Enum.sort() == [2, 3]
  end
end
