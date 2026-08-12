defmodule Mydia.Subtitles.DownloaderProviderRoutingTest do
  @moduledoc """
  Change (b): `Downloader.download/3` must resolve the provider identity
  passed in `opts` and download through that provider's adapter, instead of
  hardcoding the relay. Search already walks a user's configured provider
  chain (Task 7); before this fix, download ignored all of that and always
  hit the shared relay account, so a user's own OpenSubtitles credentials
  were used for search and never for the part that actually spends quota.
  Routing search through a provider without routing download through it is
  worse than not offering the option: it looks like it works.

  This suite uses the same `:subtitle_adapter_override` application-env stub
  used by `ProviderChainTest` (see test/mydia/subtitles/provider_chain_test.exs)
  rather than Bypass: the point under test is *which provider* the Downloader
  resolves and hands to `ProviderChain.adapter_for/1`, not any one adapter's
  own HTTP shape (that is covered by relay_test.exs / open_subtitles_test.exs
  already, both off limits for this task). A recording stub makes the
  resolved provider directly observable.
  """
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures

  alias Mydia.Subtitles
  alias Mydia.Subtitles.ProviderChain
  alias Mydia.Subtitles.Providers

  defmodule RecordingAdapter do
    @moduledoc false
    @behaviour Mydia.Subtitles.Provider

    @impl true
    def search(_provider, _params), do: {:ok, []}

    @impl true
    def download(provider, subtitle_info) do
      case Application.get_env(:mydia, :downloader_routing_test_reporter) do
        pid when is_pid(pid) -> send(pid, {:download_called, provider, subtitle_info})
        _ -> :ok
      end

      {:ok, "1\r\n00:00:01,000 --> 00:00:05,000\r\nHello there\r\n\r\n"}
    end

    @impl true
    def validate_config(config), do: {:ok, config}

    @impl true
    def quota_info(_provider), do: {:ok, Mydia.Subtitles.Provider.QuotaInfo.unlimited(:relay)}
  end

  setup do
    original_adapter = Application.get_env(:mydia, :subtitle_adapter_override)
    Application.put_env(:mydia, :subtitle_adapter_override, RecordingAdapter)
    Application.put_env(:mydia, :downloader_routing_test_reporter, self())

    on_exit(fn ->
      if is_nil(original_adapter) do
        Application.delete_env(:mydia, :subtitle_adapter_override)
      else
        Application.put_env(:mydia, :subtitle_adapter_override, original_adapter)
      end

      Application.delete_env(:mydia, :downloader_routing_test_reporter)
    end)

    %{user: user_fixture()}
  end

  defp subtitle_info(overrides \\ %{}) do
    Map.merge(
      %{
        file_id: 999,
        language: "en",
        format: "srt",
        subtitle_hash: "routing-hash-#{System.unique_integer([:positive])}",
        rating: 7.0,
        download_count: 3,
        hearing_impaired: false
      },
      overrides
    )
  end

  test "an explicit provider_id routes the download through that provider's adapter", %{
    user: user
  } do
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

    assert {:ok, subtitle} =
             Subtitles.download_subtitle(subtitle_info(), media_file.id, provider_id: provider.id)

    assert_receive {:download_called, called_provider, _subtitle_info}, 1000
    assert called_provider.id == provider.id
    assert called_provider.type == :opensubtitles

    # What gets persisted now that "provider" names a real entity: the
    # specific provider's id, not a generic type string, so a user with
    # several OpenSubtitles accounts can tell which one served a given file.
    assert subtitle.provider == provider.id
  end

  test "omitting provider_id still resolves to the zero-config relay default" do
    media_file = media_file_fixture()

    assert {:ok, subtitle} = Subtitles.download_subtitle(subtitle_info(), media_file.id)

    assert_receive {:download_called, called_provider, _subtitle_info}, 1000
    assert called_provider.id == ProviderChain.default_provider().id
    assert called_provider.type == :relay

    assert subtitle.provider == ProviderChain.default_provider().id
  end

  test "an unrecognised provider_id fails cleanly instead of silently using the relay" do
    media_file = media_file_fixture()
    bad_id = Ecto.UUID.generate()

    assert {:error, {:unknown_provider, ^bad_id}} =
             Subtitles.download_subtitle(subtitle_info(), media_file.id, provider_id: bad_id)

    # The critical assertion: the relay (or any adapter) must never have been
    # reached. A "fail cleanly" implementation that quietly falls back to the
    # relay on lookup failure would still return *some* error here in this
    # test setup, but it would do so only after calling the adapter -- this
    # catches exactly that silent-fallback bug, which the error shape alone
    # would not.
    refute_receive {:download_called, _provider, _subtitle_info}, 200
  end

  test "a provider_id that isn't a valid identifier at all fails cleanly too" do
    media_file = media_file_fixture()

    assert {:error, {:unknown_provider, "not-a-real-id"}} =
             Subtitles.download_subtitle(subtitle_info(), media_file.id,
               provider_id: "not-a-real-id"
             )

    refute_receive {:download_called, _provider, _subtitle_info}, 200
  end
end
