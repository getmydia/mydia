defmodule Mydia.SubtitlesTest do
  # async: false — this suite mutates the global :mydia, :subtitle_adapter_override
  # application env, same rationale as
  # test/mydia/subtitles/provider_chain_test.exs. Every put_env is paired with
  # an on_exit that restores the prior value, deleting the key entirely when
  # it was previously absent.
  use Mydia.DataCase, async: false

  alias Mydia.AccountsFixtures
  alias Mydia.MediaFixtures
  alias Mydia.Repo
  alias Mydia.Subtitles
  alias Mydia.Subtitles.MediaHash
  alias Mydia.Subtitles.Provider.QuotaInfo
  alias Mydia.Subtitles.Provider.SearchResult
  alias Mydia.Subtitles.Providers

  # This stub exists to pin the string-key -> atom-key conversion in
  # search_subtitles/2's private pipeline (score_results/2, calculate_score/2,
  # handle_search_results/4, generate_subtitle_hash/1) end to end, at the
  # public API boundary, under the real DB-backed media file lookup and
  # build_search_params/2 -- not just at the ProviderChain layer, which
  # already returns atom-keyed structs regardless of whether subtitles.ex
  # reads them correctly.
  defmodule StubAdapter do
    @behaviour Mydia.Subtitles.Provider

    @impl true
    def search(%{name: "broken"}, _params), do: {:error, {:transport, :nxdomain}}
    def search(%{name: "exhausted"}, _params), do: {:error, :quota_exceeded}

    def search(%{name: "hash-match"}, _params) do
      {:ok,
       [
         %SearchResult{
           file_id: 1,
           language: "en",
           format: "srt",
           subtitle_hash: "hash-match-hash",
           file_name: "movie.en.srt",
           rating: 9.0,
           download_count: 5000,
           hearing_impaired: false,
           moviehash_match: true
         }
       ]}
    end

    def search(%{name: name}, _params) do
      {:ok,
       [
         %SearchResult{
           file_id: 2,
           language: "en",
           format: "srt",
           subtitle_hash: "ordinary-hash-#{name}",
           file_name: "#{name}.srt",
           rating: 6.0,
           download_count: 10,
           hearing_impaired: false,
           moviehash_match: false
         }
       ]}
    end

    @impl true
    def download(_provider, _info),
      do: {:ok, "1\r\n00:00:01,000 --> 00:00:05,000\r\nHello there\r\n\r\n"}

    @impl true
    def validate_config(config), do: {:ok, config}

    @impl true
    def quota_info(_provider), do: {:ok, QuotaInfo.unlimited(:relay)}
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

    user = AccountsFixtures.user_fixture()
    media_item = MediaFixtures.media_item_fixture(%{type: "movie", imdb_id: "0133093"})
    media_file = MediaFixtures.media_file_fixture(%{media_item_id: media_item.id})

    {:ok, _media_hash} =
      %MediaHash{}
      |> MediaHash.changeset(%{
        media_file_id: media_file.id,
        opensubtitles_hash: "8e245d9679d31e12",
        file_size: 742_086_656,
        calculated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert()

    {:ok, user: user, media_file: media_file}
  end

  describe "search_subtitles/2 scoring conversion" do
    # This single assertion pins all fourteen string-key -> atom-key
    # conversion sites in lib/mydia/subtitles.ex at once: it only reaches
    # >= @high_confidence_threshold (150) if the hash-match bonus (100,
    # calculate_score/2 reading :moviehash_match), the metadata-match bonus
    # (50, reading :file_hash/:imdb_id from search_params, unaffected by the
    # conversion but required to clear the threshold), the rating bonus, and
    # the popularity bonus all actually fire -- which requires
    # score_results/2, calculate_score/2 and Map.put(result, :score, ...) to
    # all read/write atom keys correctly. If any single site were reverted
    # back to string-key access, `calculate_score/2` would silently score
    # that contribution as 0 (a `case` falling to its `_ -> score` clause,
    # never raising), and this assertion would fail because the total would
    # land under 150.
    test "a moviehash_match result found via a hash search scores at or above the high-confidence threshold",
         %{user: user, media_file: media_file} do
      {:ok, _} =
        Providers.create_provider(user.id, %{name: "hash-match", type: :relay, enabled: true})

      assert {:ok, %{results: [result]}} =
               Subtitles.search_subtitles(media_file.id, languages: "en", user_id: user.id)

      assert result.score >= 150
    end

    test "an ordinary metadata-only result still scores above zero", %{
      user: user,
      media_file: media_file
    } do
      {:ok, _} =
        Providers.create_provider(user.id, %{name: "ordinary", type: :relay, enabled: true})

      assert {:ok, %{results: [result]}} =
               Subtitles.search_subtitles(media_file.id, languages: "en", user_id: user.id)

      refute result.moviehash_match
      assert result.score > 0
    end
  end

  describe "search_subtitles/2 provider status reporting" do
    test "situation 1: providers answered and nothing matched reports no provider errors", %{
      user: user,
      media_file: media_file
    } do
      {:ok, _} =
        Providers.create_provider(user.id, %{name: "ordinary", type: :relay, enabled: true})

      assert {:ok, %{results: [_result], providers: [status]}} =
               Subtitles.search_subtitles(media_file.id, languages: "en", user_id: user.id)

      assert status.name == "ordinary"
      assert status.error == nil
    end

    test "situation 2: a failed provider is named and explained even though results comes back empty",
         %{user: user, media_file: media_file} do
      {:ok, _} =
        Providers.create_provider(user.id, %{name: "broken", type: :relay, enabled: true})

      assert {:ok, %{results: [], providers: [status]}} =
               Subtitles.search_subtitles(media_file.id, languages: "en", user_id: user.id)

      assert status.name == "broken"
      assert status.error != nil
      refute status.error =~ "quota"
    end

    test "situation 3: an exhausted quota is reported by name with a quota-specific reason", %{
      user: user,
      media_file: media_file
    } do
      {:ok, _} =
        Providers.create_provider(user.id, %{name: "exhausted", type: :relay, enabled: true})

      assert {:ok, %{results: [], providers: [status]}} =
               Subtitles.search_subtitles(media_file.id, languages: "en", user_id: user.id)

      assert status.name == "exhausted"
      assert status.error =~ "quota"
    end

    test "partial failure: a working provider's results survive alongside a failed sibling's status",
         %{user: user, media_file: media_file} do
      {:ok, _} =
        Providers.create_provider(user.id, %{
          name: "broken",
          type: :relay,
          priority: 10,
          enabled: true
        })

      {:ok, _} =
        Providers.create_provider(user.id, %{
          name: "ordinary",
          type: :relay,
          priority: 1,
          enabled: true
        })

      assert {:ok, %{results: results, providers: [broken_status, ok_status]}} =
               Subtitles.search_subtitles(media_file.id, languages: "en", user_id: user.id)

      assert length(results) == 1
      assert hd(results).provider_name == "ordinary"

      assert broken_status.name == "broken"
      assert broken_status.error != nil

      assert ok_status.name == "ordinary"
      assert ok_status.error == nil
    end
  end
end
