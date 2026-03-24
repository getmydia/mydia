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
    tv_show = build(:tv_show)

    %MediaFile{
      media_item: tv_show,
      episode: build(:episode, media_item: tv_show),
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
      scan_interval: 3600
    }
  end
end
