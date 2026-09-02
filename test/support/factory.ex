defmodule Mydia.Factory do
  @moduledoc """
  Factory module for generating test data using ExMachina.
  """

  use ExMachina.Ecto, repo: Mydia.Repo

  alias Mydia.Media.{MediaItem, Episode}
  alias Mydia.Library.MediaFile
  alias Mydia.Downloads.Download
  alias Mydia.Settings.LibraryPath
  alias Mydia.Accounts.User

  defoverridable insert: 1, insert: 2, insert: 3

  # Inserts, then records the episode link a media file needs to be visible.
  #
  # `Episode.media_files` is a `many_to_many` through `media_file_episodes`, so
  # a row carrying only `episode_id` is invisible on the episode page.
  # Production writers go through `Mydia.Library`, which maintains the link;
  # ExMachina inserts the struct straight into the repo, so it has to do the
  # same, or every factory-built file would be a fixture that cannot occur in
  # production. All three arities are wrapped: `insert(:media_file, attrs)` is
  # the common call.
  def insert(record), do: link_episode(super(record))
  def insert(record, attrs), do: link_episode(super(record, attrs))
  def insert(record, attrs, opts), do: link_episode(super(record, attrs, opts))

  defp link_episode(%MediaFile{episode_id: episode_id} = media_file)
       when not is_nil(episode_id) do
    {:ok, _} = Mydia.Library.ensure_episode_link(media_file)
    media_file
  end

  defp link_episode(other), do: other

  def user_factory do
    %User{
      email: sequence(:email, &"user#{&1}@example.com"),
      username: sequence(:username, &"user#{&1}"),
      password_hash: "password"
    }
  end

  def media_item_factory do
    %MediaItem{
      type: "movie",
      title: sequence(:title, &"Test Movie #{&1}"),
      year: 2024,
      monitored: true
    }
  end

  def tv_show_factory do
    struct!(
      media_item_factory(),
      %{
        type: "tv_show",
        title: sequence(:tv_title, &"Test TV Show #{&1}")
      }
    )
  end

  def episode_factory do
    %Episode{
      media_item: build(:tv_show),
      season_number: 1,
      episode_number: sequence(:episode_number, & &1),
      title: sequence(:episode_title, &"Episode #{&1}"),
      monitored: true
    }
  end

  def media_file_factory do
    %MediaFile{
      episode: build(:episode),
      path: sequence(:file_path, &"/media/shows/episode#{&1}.mkv"),
      size: 1_000_000_000,
      resolution: "1080p",
      codec: "h264"
    }
  end

  def download_factory do
    %Download{
      media_item: build(:media_item),
      title: sequence(:download_title, &"Download #{&1}"),
      download_client_id: Ecto.UUID.generate(),
      download_client: "transmission",
      indexer: "test-indexer"
    }
  end

  def library_path_factory do
    %LibraryPath{
      path: sequence(:library_path, &"/media/library#{&1}"),
      type: :movies,
      monitored: true,
      scan_interval: nil
    }
  end
end
