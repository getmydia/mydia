defmodule Mydia.Library.EdlSidecarsTest do
  use Mydia.DataCase, async: true

  import Ecto.Query

  alias Mydia.Library.EdlSidecars
  alias Mydia.Library.MediaSegment

  @edl "0.00\t25.03\t0\r\n612.48\t735.10\t3\r\n"

  setup do
    dir = Path.join(System.tmp_dir!(), "edl-sidecars-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    library_path = Mydia.SettingsFixtures.library_path_fixture(%{path: dir})
    media_file = video!(dir, library_path, "Invented Show S01E01.mkv")

    %{dir: dir, library_path: library_path, media_file: media_file}
  end

  defp video!(dir, library_path, name) do
    File.write!(Path.join(dir, name), "not really a video")

    %{library_path_id: library_path.id, relative_path: name}
    |> Mydia.MediaFixtures.media_file_fixture()
    |> Repo.preload(:library_path)
  end

  defp segments(media_file) do
    Repo.all(
      from(s in MediaSegment, where: s.media_file_id == ^media_file.id, order_by: s.start_ms)
    )
  end

  defp ranges(media_file), do: Enum.map(segments(media_file), &{&1.start_ms, &1.end_ms})

  defp insert_intro!(media_file) do
    %MediaSegment{}
    |> MediaSegment.changeset(%{
      media_file_id: media_file.id,
      type: "intro",
      start_ms: 30_000,
      end_ms: 90_000,
      source: "chapters",
      confidence: 1.0
    })
    |> Repo.insert!()
  end

  test "adopts a sidecar's breaks as commercial edl segments", %{dir: dir, media_file: mf} do
    File.write!(Path.join(dir, "Invented Show S01E01.edl"), @edl)

    assert %{adopted: 1, updated: 0, reaped: 0, errors: []} = EdlSidecars.reconcile_all([mf])

    assert [first, second] = segments(mf)
    assert {first.start_ms, first.end_ms} == {0, 25_030}
    assert {second.start_ms, second.end_ms} == {612_480, 735_100}

    for segment <- [first, second] do
      assert segment.type == "commercial"
      assert segment.source == "edl"
      assert segment.confidence == 1.0
    end
  end

  test "writes nothing when the sidecar is unchanged", %{dir: dir, media_file: mf} do
    File.write!(Path.join(dir, "Invented Show S01E01.edl"), @edl)
    EdlSidecars.reconcile_all([mf])
    before = segments(mf)

    assert %{adopted: 0, updated: 0, reaped: 0, errors: []} = EdlSidecars.reconcile_all([mf])
    assert segments(mf) == before
  end

  test "replaces the breaks when the sidecar changes", %{dir: dir, media_file: mf} do
    path = Path.join(dir, "Invented Show S01E01.edl")
    File.write!(path, @edl)
    EdlSidecars.reconcile_all([mf])

    File.write!(path, "100 200 3\n")

    assert %{updated: 1} = EdlSidecars.reconcile_all([mf])
    assert ranges(mf) == [{100_000, 200_000}]
  end

  test "reaps the breaks once the sidecar is gone, leaving other segments", %{
    dir: dir,
    media_file: mf
  } do
    path = Path.join(dir, "Invented Show S01E01.edl")
    File.write!(path, @edl)
    EdlSidecars.reconcile_all([mf])
    intro = insert_intro!(mf)

    File.rm!(path)

    assert %{reaped: 1} = EdlSidecars.reconcile_all([mf])
    assert Enum.map(segments(mf), & &1.id) == [intro.id]
  end

  test "matches the extension case-insensitively", %{dir: dir, media_file: mf} do
    File.write!(Path.join(dir, "Invented Show S01E01.EDL"), @edl)

    assert %{adopted: 1} = EdlSidecars.reconcile_all([mf])
    assert length(segments(mf)) == 2
  end

  test "a sidecar belongs only to the video with exactly its basename", %{
    dir: dir,
    library_path: library_path
  } do
    film = video!(dir, library_path, "Invented Film.mkv")
    extended = video!(dir, library_path, "Invented Film.extended.mkv")
    File.write!(Path.join(dir, "Invented Film.edl"), @edl)

    EdlSidecars.reconcile_all([film, extended])

    assert length(segments(film)) == 2
    assert segments(extended) == []
  end

  test "an unreadable sidecar keeps the breaks already known", %{dir: dir, media_file: mf} do
    path = Path.join(dir, "Invented Show S01E01.edl")
    File.write!(path, @edl)
    EdlSidecars.reconcile_all([mf])

    # A directory where the sidecar was fails to read for any user, root
    # included, unlike a `chmod 000` file.
    File.rm!(path)
    File.mkdir!(path)

    assert %{errors: [_ | _], reaped: 0} = EdlSidecars.reconcile_all([mf])
    assert length(segments(mf)) == 2
  end

  test "a sidecar with no usable lines clears the breaks", %{dir: dir, media_file: mf} do
    path = Path.join(dir, "Invented Show S01E01.edl")
    File.write!(path, @edl)
    EdlSidecars.reconcile_all([mf])

    File.write!(path, "5 10 1\n")

    assert %{updated: 1} = EdlSidecars.reconcile_all([mf])
    assert segments(mf) == []
  end

  test "an unlistable directory records an error and keeps the breaks", %{
    dir: dir,
    media_file: mf
  } do
    File.write!(Path.join(dir, "Invented Show S01E01.edl"), @edl)
    EdlSidecars.reconcile_all([mf])

    File.rm_rf!(dir)

    assert %{errors: [_ | _], reaped: 0} = EdlSidecars.reconcile_all([mf])
    assert length(segments(mf)) == 2
  end
end
