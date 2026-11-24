defmodule Mydia.Jobs.LibraryRenameTest do
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Jobs.LibraryRename

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    lp = library_path_fixture(%{path: tmp_dir, type: "movies"})
    movie = media_item_fixture(%{type: "movie", title: "Paper Comet", year: 2019})
    File.write!(Path.join(tmp_dir, "paper.comet.junk.mkv"), "x")

    media_file_fixture(%{
      media_item_id: movie.id,
      library_path_id: lp.id,
      relative_path: "paper.comet.junk.mkv"
    })

    %{lp: lp, root: tmp_dir}
  end

  test "perform renames files and broadcasts progress and completion", ctx do
    Phoenix.PubSub.subscribe(Mydia.PubSub, "library_scanner")

    assert :ok = perform_job(LibraryRename, %{"library_path_id" => ctx.lp.id})

    assert_receive {:library_rename_started, %{library_path_id: id}} when id == ctx.lp.id
    assert_receive {:library_rename_progress, %{done: 1, total: 1}}
    assert_receive {:library_rename_completed, %{renamed: 1, errors: 0}}
    refute File.exists?(Path.join(ctx.root, "paper.comet.junk.mkv"))
  end

  test "a deleted library path still broadcasts completion with an error" do
    Phoenix.PubSub.subscribe(Mydia.PubSub, "library_scanner")
    missing = Ecto.UUID.generate()

    assert {:error, :library_unavailable} =
             perform_job(LibraryRename, %{"library_path_id" => missing})

    assert_receive {:library_rename_completed,
                    %{
                      library_path_id: ^missing,
                      renamed: 0,
                      unchanged: 0,
                      conflicts: 0,
                      errors: 0,
                      error: :library_unavailable
                    }}
  end

  test "an executing sidecar cleanup of the library refuses as busy", ctx do
    Phoenix.PubSub.subscribe(Mydia.PubSub, "library_scanner")

    %{"library_path_id" => ctx.lp.id, "paths" => []}
    |> Oban.Job.new(worker: Mydia.Jobs.SidecarCleanup)
    |> Ecto.Changeset.change(state: "executing")
    |> Repo.insert!()

    assert {:error, :busy} = perform_job(LibraryRename, %{"library_path_id" => ctx.lp.id})
    assert_receive {:library_rename_completed, %{renamed: 0, errors: 0, error: :busy}}
    assert File.exists?(Path.join(ctx.root, "paper.comet.junk.mkv"))
  end

  # Oban does not run in test (`engine: false`), so `enqueue/1` cannot insert.
  # Assert the job it would insert instead.
  test "enqueue builds a media-queue job keyed on the library path", ctx do
    changeset = LibraryRename.new(%{library_path_id: ctx.lp.id})

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :queue) == "media"
    assert Ecto.Changeset.get_field(changeset, :max_attempts) == 1
  end

  # `engine: false` in test disables Oban's uniqueness enforcement, so assert
  # the configuration that production relies on instead.
  test "dedupes per library path while incomplete" do
    unique = LibraryRename.__opts__()[:unique]
    assert unique[:keys] == [:library_path_id]
    assert :executing in unique[:states]
    assert :available in unique[:states]
  end
end
