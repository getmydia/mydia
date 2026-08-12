defmodule MydiaWeb.MediaLive.Show.SubtitleEventsTest do
  @moduledoc """
  Change (b)'s LiveView half: `download_subtitle_result/2` built `subtitle_info`
  from client params but never forwarded a provider identity, so every
  download from the search-results modal used the shared relay account even
  when the search itself came from the user's own configured provider. This
  is the same class of bug Task 7's review found in this same file for
  `user_id`.

  `start_async/3` is a no-op on a socket that is not connected (see
  `FranchiseEventsTest`), so the connected variant (`transport_pid: self()`)
  is what makes the dispatched task actually run here, against a recording
  stub adapter that reports back which provider it was called with.
  """
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures

  alias MydiaWeb.MediaLive.Show.SubtitleEvents
  alias Mydia.Subtitles.ProviderChain
  alias Mydia.Subtitles.Providers

  defmodule RecordingAdapter do
    @moduledoc false
    @behaviour Mydia.Subtitles.Provider

    @impl true
    def search(_provider, _params), do: {:ok, []}

    @impl true
    def download(provider, subtitle_info) do
      case Application.get_env(:mydia, :subtitle_events_test_reporter) do
        pid when is_pid(pid) -> send(pid, {:download_called, provider, subtitle_info})
        _ -> :ok
      end

      {:ok, "1\r\n00:00:01,000 --> 00:00:05,000\r\nHi\r\n\r\n"}
    end

    @impl true
    def validate_config(config), do: {:ok, config}

    @impl true
    def quota_info(_provider), do: {:ok, Mydia.Subtitles.Provider.QuotaInfo.unlimited(:relay)}
  end

  defp stub_socket(assigns, opts) do
    defaults = %{__changed__: %{}, flash: %{}}

    %Phoenix.LiveView.Socket{
      assigns: Map.merge(defaults, assigns),
      private: %{live_temp: %{}},
      transport_pid: if(opts[:connected], do: self())
    }
  end

  setup do
    original_adapter = Application.get_env(:mydia, :subtitle_adapter_override)
    Application.put_env(:mydia, :subtitle_adapter_override, RecordingAdapter)
    Application.put_env(:mydia, :subtitle_events_test_reporter, self())

    on_exit(fn ->
      if is_nil(original_adapter) do
        Application.delete_env(:mydia, :subtitle_adapter_override)
      else
        Application.put_env(:mydia, :subtitle_adapter_override, original_adapter)
      end

      Application.delete_env(:mydia, :subtitle_events_test_reporter)
    end)

    %{user: user_fixture()}
  end

  defp download_params(overrides) do
    Map.merge(
      %{
        "file-id" => "12345",
        "language" => "en",
        "format" => "srt",
        "subtitle-hash" => "abc123"
      },
      overrides
    )
  end

  test "threads the search result's provider id into the download call", %{user: user} do
    {:ok, provider} =
      Providers.create_provider(user.id, %{
        name: "My OpenSubtitles",
        type: :opensubtitles,
        username: "user@example.com",
        password: "secret",
        priority: 5,
        enabled: true
      })

    media_file = media_file_fixture()
    socket = stub_socket(%{selected_media_file: media_file}, connected: true)

    params = download_params(%{"provider-id" => provider.id})

    {:noreply, _socket} = SubtitleEvents.download_subtitle_result(params, socket)

    assert_receive {:download_called, called_provider, _subtitle_info}, 1000
    assert called_provider.id == provider.id
    assert called_provider.type == :opensubtitles
  end

  test "the zero-config relay's synthetic (non-UUID) provider id threads through the same way" do
    media_file = media_file_fixture()
    socket = stub_socket(%{selected_media_file: media_file}, connected: true)

    params = download_params(%{"provider-id" => ProviderChain.default_provider().id})

    {:noreply, _socket} = SubtitleEvents.download_subtitle_result(params, socket)

    assert_receive {:download_called, called_provider, _subtitle_info}, 1000
    assert called_provider.id == ProviderChain.default_provider().id
  end
end
