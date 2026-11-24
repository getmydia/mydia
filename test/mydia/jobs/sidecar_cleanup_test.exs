defmodule Mydia.Jobs.SidecarCleanupTest do
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Mydia.SettingsFixtures

  alias Mydia.Jobs.SidecarCleanup

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "lib")
    File.mkdir_p!(root)

    previous = Application.get_env(:mydia, :trash_dir)
    Application.put_env(:mydia, :trash_dir, Path.join(tmp_dir, "trash"))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:mydia, :trash_dir, previous),
        else: Application.delete_env(:mydia, :trash_dir)
    end)

    %{lp: library_path_fixture(%{path: root, type: "series"}), root: root}
  end

  test "perform moves the given paths and broadcasts completion", %{lp: lp, root: root} do
    Phoenix.PubSub.subscribe(Mydia.PubSub, "library_scanner")
    nfo = Path.join(root, "old.name.nfo")
    File.write!(nfo, "x")
    File.write!(Path.join(root, "Some Film.mkv"), "x")

    assert :ok = perform_job(SidecarCleanup, %{"library_path_id" => lp.id, "paths" => [nfo]})

    assert_receive {:sidecar_cleanup_started, %{library_path_id: id}} when id == lp.id
    assert_receive {:sidecar_cleanup_completed, %{moved: 1, kept: 0, library_path_id: ^id}}
    refute File.exists?(nfo)
  end

  test "a deleted library path still broadcasts completion with an error" do
    Phoenix.PubSub.subscribe(Mydia.PubSub, "library_scanner")
    missing = Ecto.UUID.generate()

    assert {:error, :library_unavailable} =
             perform_job(SidecarCleanup, %{"library_path_id" => missing, "paths" => []})

    assert_receive {:sidecar_cleanup_completed, %{moved: 0, kept: 0, error: :library_unavailable}}
  end

  test "enqueue builds a media-queue job with the paths", %{lp: lp} do
    changeset = SidecarCleanup.new(%{library_path_id: lp.id, paths: ["/a.nfo"]})

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :queue) == "media"
    assert Ecto.Changeset.get_field(changeset, :max_attempts) == 1
  end

  # `engine: false` in test disables Oban's uniqueness enforcement, so assert
  # the configuration that production relies on instead.
  test "dedupes per library path while incomplete" do
    unique = SidecarCleanup.__opts__()[:unique]

    assert unique[:period] == :infinity
    assert unique[:keys] == [:library_path_id]
    assert Enum.sort(unique[:states]) == Enum.sort(Oban.Job.unique_states(:incomplete))
  end
end
