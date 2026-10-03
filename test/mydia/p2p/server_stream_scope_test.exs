defmodule Mydia.P2p.ServerStreamScopeTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Accounts.Scope
  alias Mydia.P2p.Server

  defp restricted_scope,
    do: Scope.for_user(restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]}))

  describe "lookup_transcode_job/2" do
    setup do
      movie = categorized_media_item_fixture(%{type: "movie"}, "movie")
      file = media_file_fixture(%{media_item_id: movie.id})
      {:ok, job} = Mydia.Downloads.get_or_create_job(file.id, "720p")
      %{job: job}
    end

    test "a hidden title's job is not found", %{job: job} do
      assert {:error, :not_found} = Server.lookup_transcode_job(restricted_scope(), job.id)
    end

    test "a visible, unfinished job is not ready", %{job: job} do
      assert {:error, :not_ready} = Server.lookup_transcode_job(Scope.unrestricted(), job.id)
    end
  end
end
