defmodule Mydia.Repo.ForeignKeyGuardTest do
  # Every case but one asserts the same result on SQLite and PostgreSQL. That
  # parity is the point: ecto_sqlite3 reports foreign key violations with no
  # constraint name, so without the guard these raise on SQLite and return a
  # changeset error on PostgreSQL. The one exception is the malformed-id case
  # below, which hits a genuinely different failure (a dump-time type error,
  # not a foreign key violation) on PostgreSQL and documents why this guard
  # does not and should not paper over it.
  use Mydia.DataCase, async: true

  import Mydia.CollectionsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Collections.CollectionItem
  alias Mydia.Subtitles.TrackSetting

  defp track_setting_changeset(media_file_id) do
    TrackSetting.changeset(%TrackSetting{}, %{
      media_file_id: media_file_id,
      track_ref: "3",
      offset_ms: 0
    })
  end

  describe "insert/2, one declared foreign key" do
    test "a valid insert is untouched" do
      media_file = media_file_fixture()

      assert {:ok, setting} = Repo.insert(track_setting_changeset(media_file.id))
      assert setting.offset_ms == 0
    end

    test "a well-formed but nonexistent id becomes a changeset error" do
      assert {:error, changeset} = Repo.insert(track_setting_changeset(Ecto.UUID.generate()))

      assert %{media_file_id: ["does not exist"]} = errors_on(changeset)
      assert changeset.action == :insert
    end

    test "a malformed id diverges by adapter, neither route through the guard alone" do
      # Ecto.Type.cast/2 for :binary_id is a bare binary check (cast_binary/1
      # in deps/ecto/lib/ecto/type.ex), not a UUID format check, on both
      # adapters: the changeset itself is valid regardless of adapter. What
      # differs is what happens next.
      #
      # On SQLite a binary_id is TEXT, so "garbage" is written as-is, fails
      # the foreign key, and this guard catches it.
      #
      # On PostgreSQL the column is a native uuid, so the same changeset
      # instead fails at dump time inside Ecto.Repo.Schema.do_insert with
      # Ecto.ChangeError: an adapter-inherent type-validation failure that has
      # nothing to do with foreign keys. It is raised by super/2 before
      # ForeignKeyGuard.run/3's `rescue error in Ecto.ConstraintError` clause
      # ever sees it, so this guard neither causes nor papers over it; it is
      # pre-existing Ecto/Postgrex behaviour.
      case Repo.__adapter__() do
        Ecto.Adapters.Postgres ->
          assert_raise Ecto.ChangeError, fn ->
            Repo.insert(track_setting_changeset("garbage"))
          end

        _ ->
          assert {:error, changeset} = Repo.insert(track_setting_changeset("garbage"))
          assert %{media_file_id: [_ | _]} = errors_on(changeset)
      end
    end
  end

  describe "insert/2, two declared foreign keys" do
    test "blames only the reference that is actually missing" do
      collection = collection_fixture()

      changeset =
        %CollectionItem{
          collection_id: collection.id,
          media_item_id: Ecto.UUID.generate()
        }
        |> CollectionItem.changeset(%{position: 0})

      assert {:error, changeset} = Repo.insert(changeset)
      errors = errors_on(changeset)

      assert %{media_item_id: ["does not exist"]} = errors
      refute Map.has_key?(errors, :collection_id)
    end
  end

  describe "update/2" do
    test "a nonexistent id becomes a changeset error" do
      media_file = media_file_fixture()
      {:ok, setting} = Repo.insert(track_setting_changeset(media_file.id))

      changeset = TrackSetting.changeset(setting, %{media_file_id: Ecto.UUID.generate()})

      assert {:error, changeset} = Repo.update(changeset)
      assert %{media_file_id: ["does not exist"]} = errors_on(changeset)
      assert changeset.action == :update
    end
  end

  describe "insert_or_update/2" do
    test "a nonexistent id becomes a changeset error" do
      assert {:error, changeset} =
               Repo.insert_or_update(track_setting_changeset(Ecto.UUID.generate()))

      assert %{media_file_id: ["does not exist"]} = errors_on(changeset)
      assert changeset.action == :insert
    end
  end

  describe "escape hatches" do
    test "a violation the changeset never declared still raises" do
      # Stripping the declared constraint leaves the guard nothing to attribute
      # to on SQLite, and leaves Ecto's own matcher nothing to match on
      # PostgreSQL. Both must stay loud: an undeclared constraint is a real bug.
      changeset = %{track_setting_changeset(Ecto.UUID.generate()) | constraints: []}

      assert_raise Ecto.ConstraintError, fn -> Repo.insert(changeset) end
    end

    test "an Ecto.Multi step halts instead of raising" do
      result =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:setting, track_setting_changeset(Ecto.UUID.generate()))
        |> Repo.transaction()

      assert {:error, :setting, changeset, %{}} = result
      assert %{media_file_id: ["does not exist"]} = errors_on(changeset)
    end
  end
end
