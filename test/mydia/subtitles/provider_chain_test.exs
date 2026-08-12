defmodule Mydia.Subtitles.ProviderChainTest do
  # async: false — this suite mutates the global :mydia, :subtitle_adapter_override
  # application env. The repo has previously shipped a suite that was green on
  # SQLite and red on PostgreSQL because concurrent tests leaked env mutations
  # into each other; every put_env here is paired with an on_exit restoring the
  # prior value (deleting the key entirely when it was previously absent).
  use Mydia.DataCase, async: false

  alias Mydia.AccountsFixtures
  alias Mydia.Subtitles.Providers
  alias Mydia.Subtitles.ProviderChain

  defmodule StubAdapter do
    @behaviour Mydia.Subtitles.Provider

    @impl true
    def search(%{name: "exhausted"}, _params), do: {:error, :quota_exceeded}
    def search(%{name: "broken"}, _params), do: {:error, {:transport, :nxdomain}}

    def search(%{name: name}, _params) do
      {:ok,
       [
         %Mydia.Subtitles.Provider.SearchResult{
           file_id: 1,
           language: "en",
           format: "srt",
           subtitle_hash: "shared-hash",
           file_name: "#{name}.srt",
           rating: 7.0,
           download_count: 100,
           hearing_impaired: false,
           moviehash_match: false
         }
       ]}
    end

    @impl true
    def download(_provider, _info), do: {:ok, "https://example.com/sub.srt"}

    @impl true
    def validate_config(config), do: {:ok, config}

    @impl true
    def quota_info(_provider),
      do: {:ok, Mydia.Subtitles.Provider.QuotaInfo.unlimited(:relay)}
  end

  setup do
    original = Application.get_env(:mydia, :subtitle_adapter_override)
    Application.put_env(:mydia, :subtitle_adapter_override, StubAdapter)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:mydia, :subtitle_adapter_override)
      else
        Application.put_env(:mydia, :subtitle_adapter_override, original)
      end
    end)

    {:ok, user: AccountsFixtures.user_fixture()}
  end

  test "synthesizes a relay provider when the user has none", %{user: user} do
    assert {:ok, %{results: results, providers: [provider]}} =
             ProviderChain.search(user.id, %{languages: "en"})

    assert length(results) == 1
    assert provider.name != nil
    assert provider.error == nil
  end

  test "walks providers in priority order", %{user: user} do
    {:ok, _low} =
      Providers.create_provider(user.id, %{name: "low", type: :relay, priority: 1, enabled: true})

    {:ok, _high} =
      Providers.create_provider(user.id, %{
        name: "high",
        type: :relay,
        priority: 10,
        enabled: true
      })

    assert {:ok, %{providers: [first, second]}} =
             ProviderChain.search(user.id, %{languages: "en"})

    assert first.name == "high"
    assert second.name == "low"
  end

  test "records a quota failure and continues to the next provider", %{user: user} do
    {:ok, _} =
      Providers.create_provider(user.id, %{
        name: "exhausted",
        type: :relay,
        priority: 10,
        enabled: true
      })

    {:ok, _} =
      Providers.create_provider(user.id, %{
        name: "working",
        type: :relay,
        priority: 1,
        enabled: true
      })

    assert {:ok, %{results: results, providers: [exhausted, working]}} =
             ProviderChain.search(user.id, %{languages: "en"})

    assert exhausted.error =~ "quota"
    assert working.error == nil
    assert length(results) == 1
    assert hd(results).provider_name == "working"
  end

  test "returns no results when every provider fails", %{user: user} do
    {:ok, _} =
      Providers.create_provider(user.id, %{name: "broken", type: :relay, enabled: true})

    assert {:ok, %{results: [], providers: [broken]}} =
             ProviderChain.search(user.id, %{languages: "en"})

    assert broken.error != nil
  end

  test "dedupes identical subtitles returned by two providers", %{user: user} do
    {:ok, _} =
      Providers.create_provider(user.id, %{name: "a", type: :relay, priority: 2, enabled: true})

    {:ok, _} =
      Providers.create_provider(user.id, %{name: "b", type: :relay, priority: 1, enabled: true})

    assert {:ok, %{results: results}} = ProviderChain.search(user.id, %{languages: "en"})

    # Both stubs return subtitle_hash "shared-hash"
    assert length(results) == 1
    assert hd(results).provider_name == "a"
  end

  test "falls through on a non-quota error too (Obligation A)", %{user: user} do
    {:ok, _} =
      Providers.create_provider(user.id, %{
        name: "broken",
        type: :relay,
        priority: 10,
        enabled: true
      })

    {:ok, _} =
      Providers.create_provider(user.id, %{
        name: "working",
        type: :relay,
        priority: 1,
        enabled: true
      })

    assert {:ok, %{results: results, providers: [broken, working]}} =
             ProviderChain.search(user.id, %{languages: "en"})

    assert broken.error != nil
    refute broken.error =~ "quota"
    assert working.error == nil
    assert length(results) == 1
    assert hd(results).provider_name == "working"
  end

  test "does not consult quota_info/1 to decide whether to try a provider (Obligation B)", %{
    user: user
  } do
    # The relay's quota_info/1 always reports :unlimited by design, even
    # though its download/2 (and, in this stub, search/2) can still fail with
    # :quota_exceeded. The chain must rely on the error returned from
    # search/2 itself, never on a quota_info/1 pre-check.
    {:ok, _} =
      Providers.create_provider(user.id, %{
        name: "exhausted",
        type: :relay,
        enabled: true
      })

    assert {:ok, %{results: [], providers: [provider]}} =
             ProviderChain.search(user.id, %{languages: "en"})

    assert provider.error =~ "quota"
  end
end
