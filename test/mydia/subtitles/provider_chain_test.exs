defmodule Mydia.Subtitles.ProviderChainTest do
  use Mydia.DataCase, async: true

  alias Mydia.Subtitles.ProviderChain
  alias Mydia.SubtitleProviderFixtures

  defmodule StubAdapter do
    @behaviour Mydia.Subtitles.Provider

    @impl true
    def search(%{name: "exhausted"}, _params), do: {:error, :quota_exceeded}
    def search(%{name: "broken"}, _params), do: {:error, {:transport, :nxdomain}}

    def search(%{name: "slow"}, _params) do
      Process.sleep(5_000)
      {:ok, []}
    end

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

    @impl true
    def capabilities do
      %{
        media_types: [:movie, :episode],
        search_keys: [:file_hash, :imdb_id, :tmdb_id, :query],
        requires_credentials: false,
        quota: :unlimited
      }
    end
  end

  defmodule EpisodeOnlyAdapter do
    @behaviour Mydia.Subtitles.Provider

    @impl true
    def search(_provider, _params), do: {:ok, []}

    @impl true
    def download(_provider, _info), do: {:ok, ""}

    @impl true
    def validate_config(config), do: {:ok, config}

    @impl true
    def quota_info(_provider),
      do: {:ok, Mydia.Subtitles.Provider.QuotaInfo.unlimited(:relay)}

    @impl true
    def capabilities do
      %{
        media_types: [:episode],
        search_keys: [:tvdb_id],
        requires_credentials: false,
        quota: :unlimited
      }
    end
  end

  test "returns results from the registry defaults when no rows exist" do
    # The registry declares :relay enabled by default, so a fresh install
    # searches successfully with an empty subtitle_provider_configs table.
    SubtitleProviderFixtures.stub_registry_adapter(:relay, StubAdapter)

    assert {:ok, %{results: results, providers: [provider]}} =
             ProviderChain.search(%{languages: "en", media_type: "movie"})

    assert length(results) == 1
    assert provider.error == nil
  end

  test "returns partial results when one provider exceeds its deadline" do
    SubtitleProviderFixtures.config_fixture(%{
      name: "slow",
      adapter: StubAdapter,
      connection_settings: %{"timeout" => 100}
    })

    SubtitleProviderFixtures.config_fixture(%{name: "fast", adapter: StubAdapter})

    assert {:ok, %{results: results, providers: providers}} =
             ProviderChain.search(%{languages: "en", media_type: "movie"})

    # The fast provider's result survives even though the slow one never answers.
    assert length(results) == 1
    assert hd(results).provider_name == "fast"

    slow = Enum.find(providers, &(&1.name == "slow"))
    assert slow.error =~ "not respond"
  end

  test "skips a provider whose capabilities cannot serve the query" do
    SubtitleProviderFixtures.config_fixture(%{name: "tv-only", adapter: EpisodeOnlyAdapter})
    SubtitleProviderFixtures.config_fixture(%{name: "general", adapter: StubAdapter})

    assert {:ok, %{providers: providers}} =
             ProviderChain.search(%{languages: "en", media_type: "movie"})

    assert Enum.map(providers, & &1.name) == ["general"]
  end

  test "records a failing provider and still returns the others' results" do
    SubtitleProviderFixtures.config_fixture(%{name: "exhausted", adapter: StubAdapter})
    SubtitleProviderFixtures.config_fixture(%{name: "working", adapter: StubAdapter})

    assert {:ok, %{results: results, providers: providers}} =
             ProviderChain.search(%{languages: "en", media_type: "movie"})

    exhausted = Enum.find(providers, &(&1.name == "exhausted"))
    working = Enum.find(providers, &(&1.name == "working"))

    assert exhausted.error =~ "quota"
    assert working.error == nil
    assert length(results) == 1
    assert hd(results).provider_name == "working"
  end

  test "ranks results tied on score by provider priority" do
    SubtitleProviderFixtures.config_fixture(%{name: "low", priority: 1, adapter: StubAdapter})
    SubtitleProviderFixtures.config_fixture(%{name: "high", priority: 10, adapter: StubAdapter})

    assert {:ok, %{results: results}} =
             ProviderChain.search(%{languages: "en", media_type: "movie"})

    # Both stubs return subtitle_hash "shared-hash", so dedupe keeps one and
    # priority decides which survives.
    assert length(results) == 1
    assert hd(results).provider_name == "high"
  end

  test "returns no results when every provider fails" do
    SubtitleProviderFixtures.config_fixture(%{name: "broken", adapter: StubAdapter})

    assert {:ok, %{results: [], providers: [broken]}} =
             ProviderChain.search(%{languages: "en", media_type: "movie"})

    assert broken.error != nil
  end
end
