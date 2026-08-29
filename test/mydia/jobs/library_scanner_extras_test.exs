defmodule Mydia.Jobs.LibraryScannerExtrasTest do
  # Touches the filesystem and the scanner, so no async.
  use Mydia.DataCase, async: false

  alias Mydia.Jobs.LibraryScanner
  alias Mydia.Library.MediaFile

  import Mydia.SettingsFixtures
  import Mydia.MetadataCacheHelpers

  # Every "Ratatouille (2007)" file the scanner cannot match locally sends
  # MetadataMatcher.search_external_movie/3 to the live relay — one search
  # per file, all for the same title+year, so warming it once covers however
  # many files a given test scans (#530). A non-empty, matching result is
  # required: an empty match triggers search_external_movie/3's own
  # retry-without-year fallback, which is a different, separately-cached
  # search that would escape all over again.
  defp warm_ratatouille_search do
    warm_movie_search_cache("Ratatouille", [year: 2007], [
      %{
        "id" => unique_provider_id(),
        "title" => "Ratatouille",
        "release_date" => "2007-06-22",
        "popularity" => 50.0
      }
    ])
  end

  defp scan(library_path) do
    LibraryScanner.perform(%Oban.Job{args: %{"library_path_id" => library_path.id}})
  end

  defp files_for(library_path) do
    MediaFile.active()
    |> Mydia.Repo.all()
    |> Enum.filter(&(&1.library_path_id == library_path.id))
    |> Map.new(&{Path.basename(&1.relative_path), &1})
  end

  @tag :tmp_dir
  test "a flat movie folder persists its extras as flagged rows", %{tmp_dir: tmp_dir} do
    movie_dir = Path.join(tmp_dir, "Ratatouille (2007)")
    File.mkdir_p!(movie_dir)

    # A feature plus two extras the filename layer catches. The extras only the
    # duration layer can catch are covered by the classifier tests; this test
    # is about persistence, not detection strength.
    File.write!(Path.join(movie_dir, "Ratatouille.2007.1080p.BluRay.mkv"), "feature")
    File.write!(Path.join(movie_dir, "gusteau-featurette.mkv"), "extra")
    File.write!(Path.join(movie_dir, "ratatouille-trailer.mkv"), "trailer")

    warm_ratatouille_search()

    library_path = library_path_fixture(%{path: tmp_dir, type: "movies"})
    scan(library_path)

    files = files_for(library_path)

    assert map_size(files) == 3,
           "expected extras to be persisted, not dropped: #{inspect(Map.keys(files))}"

    assert files["Ratatouille.2007.1080p.BluRay.mkv"].extra_kind == nil
    assert files["gusteau-featurette.mkv"].extra_kind == :other
    assert files["gusteau-featurette.mkv"].extra_source == :filename
    assert files["ratatouille-trailer.mkv"].extra_kind == :trailer
    assert files["ratatouille-trailer.mkv"].extra_source == :filename
  end

  @tag :tmp_dir
  test "a Plex extras subfolder gets its named kind", %{tmp_dir: tmp_dir} do
    scenes_dir = Path.join([tmp_dir, "Ratatouille (2007)", "Deleted Scenes"])
    File.mkdir_p!(scenes_dir)
    File.write!(Path.join(scenes_dir, "cut.mkv"), "extra")

    library_path = library_path_fixture(%{path: tmp_dir, type: "movies"})
    scan(library_path)

    files = files_for(library_path)

    assert files["cut.mkv"].extra_kind == :deleted_scene
    assert files["cut.mkv"].extra_source == :folder
  end

  @tag :tmp_dir
  test "versions/0 hides the extras the scanner just created", %{tmp_dir: tmp_dir} do
    movie_dir = Path.join(tmp_dir, "Ratatouille (2007)")
    File.mkdir_p!(movie_dir)
    File.write!(Path.join(movie_dir, "Ratatouille.2007.1080p.BluRay.mkv"), "feature")
    File.write!(Path.join(movie_dir, "gusteau-featurette.mkv"), "extra")

    warm_ratatouille_search()

    library_path = library_path_fixture(%{path: tmp_dir, type: "movies"})
    scan(library_path)

    versions =
      MediaFile.versions()
      |> Mydia.Repo.all()
      |> Enum.filter(&(&1.library_path_id == library_path.id))

    assert length(versions) == 1
    assert Path.basename(hd(versions).relative_path) == "Ratatouille.2007.1080p.BluRay.mkv"
  end
end
