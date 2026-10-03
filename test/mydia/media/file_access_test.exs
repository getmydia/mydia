defmodule Mydia.Media.FileAccessTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Accounts.Scope
  alias Mydia.Media.FileAccess

  defp restricted_scope,
    do: Scope.for_user(restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]}))

  defp hidden_movie_file do
    movie = categorized_media_item_fixture(%{type: "movie"}, "movie")
    media_file_fixture(%{media_item_id: movie.id})
  end

  defp hidden_episode_file do
    show = categorized_media_item_fixture(%{type: "tv_show"}, "tv_show")
    episode = episode_fixture(%{media_item_id: show.id})
    media_file_fixture(%{episode_id: episode.id})
  end

  describe "authorize/2" do
    test "an unrestricted scope reaches any file" do
      assert :ok = FileAccess.authorize(Scope.unrestricted(), hidden_movie_file())
    end

    test "a restricted scope is denied a hidden movie file" do
      assert :denied = FileAccess.authorize(restricted_scope(), hidden_movie_file())
    end

    test "a restricted scope is denied a hidden episode file (media_item_id is nil)" do
      assert :denied = FileAccess.authorize(restricted_scope(), hidden_episode_file())
    end

    test "a nil scope is denied" do
      assert :denied = FileAccess.authorize(nil, hidden_movie_file())
    end
  end

  describe "authorize_id/2" do
    test "returns the file when visible" do
      file = hidden_movie_file()
      assert {:ok, %{id: id}} = FileAccess.authorize_id(Scope.unrestricted(), file.id)
      assert id == file.id
    end

    test "a hidden, a missing and a malformed id all read as :denied" do
      assert :denied = FileAccess.authorize_id(restricted_scope(), hidden_movie_file().id)
      assert :denied = FileAccess.authorize_id(Scope.unrestricted(), Ecto.UUID.generate())
      assert :denied = FileAccess.authorize_id(Scope.unrestricted(), "not-a-uuid")
    end
  end
end
