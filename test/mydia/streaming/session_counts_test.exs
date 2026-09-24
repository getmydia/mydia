defmodule Mydia.Streaming.SessionCountsTest do
  # Registers into the real, global session registry.
  use ExUnit.Case, async: false

  alias Mydia.Streaming

  @registry Mydia.Streaming.HlsSessionRegistry

  test "counts each session once, by kind and HLS mode" do
    before = Streaming.session_counts()
    id = fn -> Ecto.UUID.generate() end

    {:ok, _} = Registry.register(@registry, {:hls_session, id.(), id.()}, %{mode: :copy})
    {:ok, _} = Registry.register(@registry, {:hls_session, id.(), id.()}, %{mode: :transcode})
    # An HLS session's second key must not count twice.
    {:ok, _} = Registry.register(@registry, {:session, id.()}, %{mode: :transcode})
    # Metadata without a mode counts as transcode, as list_active_sessions/0 does.
    {:ok, _} = Registry.register(@registry, {:hls_session, id.(), id.()}, %{})
    {:ok, _} = Registry.register(@registry, {:direct_session, id.(), id.()}, %{})
    {:ok, _} = Registry.register(@registry, {:remux_session, id.(), id.()}, %{})

    assert Streaming.session_counts() == %{
             hls_copy: before.hls_copy + 1,
             hls_transcode: before.hls_transcode + 2,
             direct: before.direct + 1,
             remux: before.remux + 1
           }
  end
end
