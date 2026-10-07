defmodule Mydia.Streaming.HlsSessionMissingInputTest do
  @moduledoc """
  A session whose input cannot be resolved must fail to start without leaving
  its "transcoding" queue row behind: init/1 inserts the row before the backend
  starts, and a failed init never reaches terminate/2.
  """
  use Mydia.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Mydia.Downloads.TranscodeJob
  alias Mydia.Streaming.HlsSessionSupervisor

  test "a missing local file fails the start and leaves no job row" do
    # The fixture's library directory exists but the file inside it does not.
    media_file = Mydia.MediaFixtures.media_file_fixture(%{})
    user = Mydia.AccountsFixtures.user_fixture()

    assert {:error, {:backend_start_failed, :input_unavailable}} =
             HlsSessionSupervisor.start_session(media_file.id, user.id)

    refute Mydia.Repo.exists?(from j in TranscodeJob, where: j.media_file_id == ^media_file.id)
  end
end
