defmodule Mydia.Jobs.ExtraClassificationTest do
  use Mydia.DataCase, async: false

  alias Mydia.Jobs.ExtraClassification
  alias Mydia.Library.MediaFile
  alias Mydia.Repo

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  defp movie(runtime_minutes) do
    media_item_fixture(%{type: "movie", metadata: %{runtime: runtime_minutes}})
  end

  defp file(item, library_path, duration_seconds, overrides \\ %{}) do
    attrs =
      Enum.into(overrides, %{
        media_item_id: item.id,
        library_path_id: library_path.id,
        relative_path: "#{item.title}/#{System.unique_integer([:positive])}.mkv",
        analyzed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        metadata: %{duration: duration_seconds}
      })

    %MediaFile{} |> MediaFile.changeset(attrs) |> Repo.insert!()
  end

  defp run, do: ExtraClassification.perform(%Oban.Job{args: %{}})

  setup do
    %{library_path: library_path_fixture(%{type: "movies"})}
  end

  test "demotes a short file and leaves the feature alone", %{library_path: lp} do
    item = movie(111)
    feature = file(item, lp, 111 * 60)
    extra = file(item, lp, 3 * 60)

    assert :ok = run()

    assert Repo.reload!(feature).extra_kind == nil
    assert Repo.reload!(extra).extra_kind == :other
    assert Repo.reload!(extra).extra_source == :duration
  end

  test "stamps extra_checked_at on files it leaves as versions", %{library_path: lp} do
    item = movie(111)
    feature = file(item, lp, 111 * 60)

    assert :ok = run()

    assert Repo.reload!(feature).extra_checked_at
  end

  test "selects rows on a freshly migrated database", %{library_path: lp} do
    # Every row starts with extra_source IS NULL. Writing the guard as
    # `extra_source != :operator` makes SQL three-valued logic drop exactly
    # these rows, and the worker silently does nothing forever.
    item = movie(111)
    _feature = file(item, lp, 111 * 60)
    extra = file(item, lp, 3 * 60)

    assert :ok = run()
    assert Repo.reload!(extra).extra_kind == :other
  end

  test "never overwrites an operator decision", %{library_path: lp} do
    item = movie(111)
    _feature = file(item, lp, 111 * 60)

    promoted =
      file(item, lp, 3 * 60, %{
        extra_kind: nil,
        extra_source: :operator,
        extra_checked_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    assert :ok = run()

    assert Repo.reload!(promoted).extra_kind == nil
    assert Repo.reload!(promoted).extra_source == :operator
  end

  test "never overwrites a folder or filename decision", %{library_path: lp} do
    item = movie(111)
    _feature = file(item, lp, 111 * 60)

    # A feature-length file in a Deleted Scenes folder stays an extra: folder
    # beats duration.
    long_extra = file(item, lp, 110 * 60, %{extra_kind: :deleted_scene, extra_source: :folder})

    assert :ok = run()

    assert Repo.reload!(long_extra).extra_kind == :deleted_scene
    assert Repo.reload!(long_extra).extra_source == :folder
  end

  test "ignores files attached to a tv show", %{library_path: lp} do
    # media_item_id IS NOT NULL is not a movie filter. On galactica 123 of 477
    # such rows hang off a show that has no episode link yet.
    show = media_item_fixture(%{type: "tv_show", metadata: %{runtime: 45}})
    orphan = file(show, lp, 3 * 60)

    assert :ok = run()

    assert Repo.reload!(orphan).extra_kind == nil
    assert Repo.reload!(orphan).extra_checked_at == nil
  end

  test "ignores unanalysed files", %{library_path: lp} do
    item = movie(111)
    _feature = file(item, lp, 111 * 60)
    pending = file(item, lp, nil, %{analyzed_at: nil, metadata: %{}})

    assert :ok = run()

    assert Repo.reload!(pending).extra_checked_at == nil
  end

  test "ignores trashed files", %{library_path: lp} do
    item = movie(111)
    _feature = file(item, lp, 111 * 60)

    trashed =
      file(item, lp, 3 * 60, %{trashed_at: DateTime.utc_now() |> DateTime.truncate(:second)})

    assert :ok = run()

    assert Repo.reload!(trashed).extra_checked_at == nil
  end

  test "is idempotent", %{library_path: lp} do
    item = movie(111)
    feature = file(item, lp, 111 * 60)
    extra = file(item, lp, 3 * 60)

    assert :ok = run()
    assert :ok = run()

    assert Repo.reload!(feature).extra_kind == nil
    assert Repo.reload!(extra).extra_kind == :other
  end

  test "does not promote a second version when an operator version already exists",
       %{library_path: lp} do
    item = movie(111)

    operator_version =
      file(item, lp, 20 * 60, %{
        extra_kind: nil,
        extra_source: :operator,
        extra_checked_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    # Longer than the operator's file and above the 0.30 rescue floor (0.36),
    # so an unsuppressed invariant would promote it.
    borderline = file(item, lp, 40 * 60)

    assert :ok = run()

    assert Repo.reload!(operator_version).extra_kind == nil

    assert Repo.reload!(borderline).extra_kind == :other,
           "the rescue must not fire when a protected version already exists"
  end
end
