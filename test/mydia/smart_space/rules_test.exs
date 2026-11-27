defmodule Mydia.SmartSpace.RulesTest do
  use Mydia.DataCase

  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures

  alias Mydia.SmartSpace.{Keep, Override, Rules}

  defp show, do: media_item_fixture(%{type: "tv_show", title: "Harbor Lights"})

  describe "overrides" do
    test "custom requires unit and grace_days" do
      s = show()
      assert {:error, cs} = Rules.put_override(s.id, %{mode: "custom"})
      assert %{unit: _, grace_days: _} = errors_on(cs)

      assert {:ok, %Override{mode: "custom", unit: "season", grace_days: 3}} =
               Rules.put_override(s.id, %{mode: "custom", unit: "season", grace_days: 3})
    end

    test "rejects non-TV items" do
      movie = media_item_fixture(%{type: "movie"})
      assert {:error, cs} = Rules.put_override(movie.id, %{mode: "off"})
      assert %{media_item_id: _} = errors_on(cs)
    end

    test "put updates the existing row and off needs no unit" do
      s = show()
      {:ok, a} = Rules.put_override(s.id, %{mode: "custom", unit: "episode", grace_days: 1})
      {:ok, b} = Rules.put_override(s.id, %{mode: "off"})
      assert a.id == b.id
      assert Rules.get_override(s.id).mode == "off"
      assert [_] = Rules.list_overrides()
    end

    test "inherit with string keys deletes the row and is never stored" do
      s = show()
      {:ok, _} = Rules.put_override(s.id, %{"mode" => "off"})
      assert {:ok, nil} = Rules.put_override(s.id, %{"mode" => "inherit"})
      assert Rules.get_override(s.id) == nil
      assert {:ok, nil} = Rules.put_override(s.id, %{"mode" => "inherit"})

      cs = Override.changeset(%Override{media_item_id: s.id}, %{mode: "inherit"})
      refute cs.valid?
    end

    test "inherit deletes the row" do
      s = show()
      {:ok, _} = Rules.put_override(s.id, %{mode: "off"})
      assert {:ok, nil} = Rules.put_override(s.id, %{mode: "inherit"})
      assert Rules.get_override(s.id) == nil
    end
  end

  describe "keeps" do
    test "keep is idempotent at every level" do
      s = show()
      ep = episode_fixture(%{media_item_id: s.id})
      user = user_fixture()

      for target <- [{:show, s.id}, {:season, s.id, 1}, {:episode, s.id, ep.id}] do
        assert {:ok, a} = Rules.keep(target, user)
        assert {:ok, b} = Rules.keep(target, nil)
        assert a.id == b.id
      end

      assert length(Rules.list_keeps()) == 3
    end

    test "keep rejects targets that do not belong to the show" do
      s = show()
      other = show()
      movie = media_item_fixture(%{type: "movie"})
      own = episode_fixture(%{media_item_id: s.id, season_number: 1})
      foreign = episode_fixture(%{media_item_id: other.id, season_number: 4})

      assert {:error, :invalid_target} = Rules.keep({:show, movie.id}, nil)
      assert {:error, :invalid_target} = Rules.keep({:episode, s.id, foreign.id}, nil)
      assert {:error, :invalid_target} = Rules.keep({:episode, s.id, "nope"}, nil)
      assert {:error, :invalid_target} = Rules.keep({:season, s.id, 4}, nil)
      assert {:ok, _} = Rules.keep({:episode, s.id, own.id}, nil)
      assert Rules.list_keeps(media_item_id: s.id) |> length() == 1
      assert Rules.list_keeps(media_item_id: other.id) == []
    end

    test "list_keeps narrows and preloads, unkeep removes" do
      s = show()
      other = show()
      ep = episode_fixture(%{media_item_id: s.id})
      {:ok, _} = Rules.keep({:episode, s.id, ep.id}, nil)
      {:ok, _} = Rules.keep({:show, other.id}, nil)

      assert [%Keep{episode: %{id: id}, media_item: %{id: sid}}] =
               Rules.list_keeps(media_item_id: s.id)

      assert id == ep.id and sid == s.id

      assert :ok = Rules.unkeep({:episode, s.id, ep.id})
      assert :ok = Rules.unkeep({:episode, s.id, ep.id})
      assert Rules.list_keeps(media_item_id: s.id) == []
    end

    test "season and episode together is rejected" do
      s = show()
      ep = episode_fixture(%{media_item_id: s.id})

      cs =
        %Keep{media_item_id: s.id, season_number: 1, episode_id: ep.id}
        |> Keep.changeset()

      refute cs.valid?
    end

    test "database CHECK rejects season and episode together" do
      s = show()
      ep = episode_fixture(%{media_item_id: s.id})

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%Keep{media_item_id: s.id, season_number: 1, episode_id: ep.id})
      end
    end

    test "unique indexes backstop duplicates" do
      s = show()
      insert = fn -> Repo.insert(Keep.changeset(%Keep{media_item_id: s.id})) end
      assert {:ok, _} = insert.()
      assert {:error, cs} = insert.()
      assert %{media_item_id: _} = errors_on(cs)
    end

    test "an insert that loses the race returns the winner's keep" do
      s = show()
      insert = fn -> Repo.insert(Keep.changeset(%Keep{media_item_id: s.id, season_number: 2})) end
      assert {:ok, winner} = insert.()
      assert {:error, cs} = insert.()

      assert {:ok, %Keep{id: id}} = Rules.recover_lost_race({:season, s.id, 2}, cs)
      assert id == winner.id
    end

    test "a non-conflict error is returned as is" do
      s = show()
      cs = Keep.changeset(%Keep{}) |> Map.put(:action, :insert)
      assert {:error, ^cs} = Rules.recover_lost_race({:show, s.id}, cs)
    end
  end

  test "deleting the media item cascades overrides and keeps" do
    s = show()
    ep = episode_fixture(%{media_item_id: s.id})
    {:ok, _} = Rules.put_override(s.id, %{mode: "off"})
    {:ok, _} = Rules.keep({:show, s.id}, nil)
    {:ok, _} = Rules.keep({:episode, s.id, ep.id}, nil)

    Repo.delete!(s)

    assert Rules.list_overrides() == []
    assert Rules.list_keeps() == []
  end
end
