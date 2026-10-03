defmodule MydiaWeb.Schema.DownloadMutationsTest do
  @moduledoc """
  Regression coverage for `DownloadService.get_media_file/2` hard-coding
  `Scope.system()`.

  `downloadOptions` and `prepareDownload` share `DownloadService.get_media_file/3`
  with the REST download endpoints. Before this fix, the GraphQL resolvers called
  the two-arg version, which always resolved media through `Scope.system()`
  regardless of who was asking, so a restricted account could enumerate quality
  options and queue a transcode for media outside its allowed categories through
  this mutation even after the REST controller was guarded.
  """

  use MydiaWeb.ConnCase, async: false

  import Ecto.Query

  alias Mydia.AccountsFixtures
  alias Mydia.Accounts.Scope
  alias Mydia.Media
  alias Mydia.Media.MediaItem
  alias Mydia.MediaFixtures
  alias Mydia.Repo

  @download_options_mutation """
  mutation DownloadOptions($contentType: String!, $id: ID!) {
    downloadOptions(contentType: $contentType, id: $id) {
      resolution
    }
  }
  """

  @prepare_download_mutation """
  mutation PrepareDownload($contentType: String!, $id: ID!) {
    prepareDownload(contentType: $contentType, id: $id) {
      jobId
    }
  }
  """

  defp restricted_movie do
    {:ok, item} =
      Media.create_media_item(
        Scope.system(),
        %{type: "movie", title: "Restricted Download Movie", year: 2024},
        skip_episode_refresh: true
      )

    Repo.update_all(from(m in MediaItem, where: m.id == ^item.id), set: [category: "movie"])
    item = Repo.get!(MediaItem, item.id)

    MediaFixtures.media_file_fixture(%{media_item_id: item.id})

    item
  end

  defp context_for(user) do
    %{current_user: user, current_scope: Scope.for_user(user)}
  end

  test "downloadOptions denies a restricted user for a category outside their scope" do
    movie = restricted_movie()
    user = AccountsFixtures.restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]})

    {:ok, result} =
      Absinthe.run(
        @download_options_mutation,
        MydiaWeb.Schema,
        variables: %{"contentType" => "movie", "id" => movie.id},
        context: context_for(user)
      )

    assert %{errors: [%{message: message}]} = result
    assert message == "Media not found"
  end

  test "prepareDownload denies a restricted user for a category outside their scope" do
    movie = restricted_movie()
    user = AccountsFixtures.restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]})

    {:ok, result} =
      Absinthe.run(
        @prepare_download_mutation,
        MydiaWeb.Schema,
        variables: %{"contentType" => "movie", "id" => movie.id},
        context: context_for(user)
      )

    assert %{errors: [%{message: message}]} = result
    assert message == "Media not found"
  end

  test "downloadOptions still answers for an unrestricted user" do
    movie = restricted_movie()
    user = AccountsFixtures.user_fixture()

    {:ok, result} =
      Absinthe.run(
        @download_options_mutation,
        MydiaWeb.Schema,
        variables: %{"contentType" => "movie", "id" => movie.id},
        context: context_for(user)
      )

    assert %{data: %{"downloadOptions" => options}} = result
    refute is_nil(options)
    assert options != []
  end

  @job_status_mutation """
  mutation DownloadJobStatus($jobId: ID!) { downloadJobStatus(jobId: $jobId) { jobId status } }
  """

  @cancel_job_mutation """
  mutation CancelDownloadJob($jobId: ID!) { cancelDownloadJob(jobId: $jobId) { success } }
  """

  describe "job mutations for a title outside the caller's scope" do
    setup do
      movie = restricted_movie()
      [file] = Mydia.Library.get_media_files_for_item(movie.id)
      {:ok, job} = Mydia.Downloads.get_or_create_job(file.id, "720p")
      user = AccountsFixtures.restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]})
      %{job: job, user: user}
    end

    test "downloadJobStatus reads as not found", %{job: job, user: user} do
      {:ok, result} =
        Absinthe.run(@job_status_mutation, MydiaWeb.Schema,
          variables: %{"jobId" => job.id},
          context: context_for(user)
        )

      assert %{errors: [%{message: "Job not found"}]} = result
    end

    test "cancelDownloadJob reads as not found and cancels nothing", %{job: job, user: user} do
      {:ok, result} =
        Absinthe.run(@cancel_job_mutation, MydiaWeb.Schema,
          variables: %{"jobId" => job.id},
          context: context_for(user)
        )

      assert %{errors: [%{message: "Job not found"}]} = result
      assert Repo.get(Mydia.Downloads.TranscodeJob, job.id)
    end
  end
end
