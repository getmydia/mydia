defmodule Mydia.Streaming.HlsSessionS3Test do
  @moduledoc """
  A real FFmpeg HLS session reading its input from S3. The session resolves a
  presigned URL on every (re)start of the backend, so none is held in state.
  """
  use Mydia.DataCase, async: false

  @moduletag :s3
  @moduletag :ffmpeg
  @moduletag :tmp_dir

  alias Mydia.Streaming.{Candidates, Compatibility, HlsSession, HlsSessionSupervisor}

  setup %{tmp_dir: tmp_dir} do
    {media_file, loc} = Mydia.S3Helpers.s3_media_file!(tmp_dir: tmp_dir)
    on_exit(fn -> Mydia.S3Helpers.delete_prefix!(loc) end)

    library_path =
      Mydia.SettingsFixtures.library_path_fixture(%{path: String.trim_trailing(loc.uri, "/")})

    persisted =
      Mydia.MediaFixtures.media_file_fixture(%{
        library_path_id: library_path.id,
        relative_path: media_file.relative_path
      })

    %{media_file: Mydia.Repo.preload(persisted, :library_path)}
  end

  test "an HLS session reaches its first playlist from an S3 object", %{media_file: mf} do
    user = Mydia.AccountsFixtures.user_fixture()

    assert {:ok, pid} = HlsSessionSupervisor.start_session(mf.id, user.id)
    on_exit(fn -> HlsSessionSupervisor.stop_session(mf.id, user.id) end)

    assert :ok = HlsSession.await_ready(pid, 30_000)
  end

  test "ensure_codec_info analyzes an S3 file", %{media_file: mf} do
    mf = %{mf | analyzed_at: nil, analysis_attempts: 0}
    result = Candidates.ensure_codec_info(mf)
    assert result.analyzed_at != nil
  end

  test "container falls back to the relative path extension", %{media_file: mf} do
    mf = %{mf | metadata: nil}
    assert Compatibility.get_container_format(mf) == "mp4"
  end
end
