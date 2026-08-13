defmodule MydiaWeb.MediaLive.Show.LoadersTranscodeJobsTest do
  use Mydia.DataCase

  alias Mydia.Downloads
  alias MydiaWeb.MediaLive.Show.Loaders

  describe "load_transcode_jobs/1" do
    setup do
      library = insert(:library_path, type: :series)
      show = insert(:tv_show)
      episode = insert(:episode, media_item: show)

      media_file =
        insert(:media_file,
          episode: episode,
          library_path: library,
          relative_path: "s01e01.mkv"
        )

      media_item = Repo.preload(show, [:media_files, episodes: :media_files])

      %{media_item: media_item, media_file: media_file}
    end

    test "omits original download jobs, which have no transcoded artifact", %{
      media_item: media_item,
      media_file: media_file
    } do
      {:ok, _job} = Downloads.get_or_create_job(media_file.id, "original")

      assert Loaders.load_transcode_jobs(media_item) == %{}
    end

    test "keeps download jobs for transcoded resolutions", %{
      media_item: media_item,
      media_file: media_file
    } do
      {:ok, job} = Downloads.get_or_create_job(media_file.id, "720p")
      file_id = media_file.id

      assert %{^file_id => [loaded]} = Loaders.load_transcode_jobs(media_item)
      assert loaded.id == job.id
    end
  end
end
