defmodule Mydia.Streaming.SessionRegistryListingTest do
  @moduledoc """
  Pins that a session is listed once, however many registry keys it holds.

  `HlsSession` registers itself twice in `Mydia.Streaming.HlsSessionRegistry`:
  under the `{:hls_session, media_file_id, user_id}` key the supervisor names it
  with, and again under `{:session, session_id}` so a segment request can find
  it in O(1) (`hls_session.ex`, `start_registered_session/7`). Selecting the
  registry without discriminating on the key therefore reported every
  transcoding viewer twice, and the dashboard rendered two identical Now
  Playing cards, sharing one DOM id, for a single stream.

  Driven through a stub holding the same pair of keys rather than a live
  session: `HlsSession.init/1` loads a real media file and spawns a real
  FFmpeg, neither of which this assertion needs. Same convention as
  `hls_session_info_test.exs` in this directory.
  """

  # Registers into the real session registry, and the stub process touches the
  # sandbox, so this cannot run async.
  use Mydia.DataCase, async: false

  alias Mydia.MediaFixtures
  alias Mydia.Streaming
  alias Mydia.Streaming.HlsSessionSupervisor

  @registry Mydia.Streaming.HlsSessionRegistry

  defmodule DoubleRegisteredSession do
    @moduledoc false
    # Stands in for a running `HlsSession`: one process, both of the registry
    # keys a real one holds, answering `:get_info` on either.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      media_file_id = Keyword.fetch!(opts, :media_file_id)
      user_id = Keyword.fetch!(opts, :user_id)
      session_id = Keyword.fetch!(opts, :session_id)
      registry = Keyword.fetch!(opts, :registry)

      meta = %{
        media_file_id: media_file_id,
        user_id: user_id,
        mode: :transcode,
        started_at: DateTime.utc_now()
      }

      {:ok, _} = Registry.register(registry, {:hls_session, media_file_id, user_id}, meta)
      {:ok, _} = Registry.register(registry, {:session, session_id}, meta)

      {:ok, %{media_file_id: media_file_id, session_id: session_id}}
    end

    @impl true
    def handle_call(:get_info, _from, state) do
      info = %{
        session_id: state.session_id,
        media_file_id: state.media_file_id,
        mode: :transcode,
        plan: nil
      }

      {:reply, {:ok, info}, state}
    end
  end

  defp start_double_registered_session(media_file, user) do
    {:ok, pid} =
      start_supervised(
        {DoubleRegisteredSession,
         media_file_id: media_file.id,
         user_id: user.id,
         session_id: Ecto.UUID.generate(),
         registry: @registry}
      )

    pid
  end

  test "list_sessions/0 skips the by-session-id lookup key" do
    media_file = MediaFixtures.media_file_fixture(%{})
    user = Mydia.AccountsFixtures.user_fixture()

    start_double_registered_session(media_file, user)

    entries =
      HlsSessionSupervisor.list_sessions()
      |> Enum.filter(fn {_key, _pid, meta} -> meta[:media_file_id] == media_file.id end)

    assert [{{:hls_session, _, _}, _pid, _meta}] = entries
  end

  test "a transcoding viewer produces one now-playing card, not two" do
    movie = MediaFixtures.media_item_fixture(%{type: "movie", title: "The Sundial Coast"})
    media_file = MediaFixtures.media_file_fixture(%{media_item_id: movie.id})
    user = Mydia.AccountsFixtures.user_fixture()

    start_double_registered_session(media_file, user)

    sessions =
      Streaming.list_active_sessions()
      |> Enum.filter(&(&1.media_file_id == media_file.id))

    assert length(sessions) == 1
  end
end
