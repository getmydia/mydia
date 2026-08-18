defmodule Mydia.Metadata.CacheLanguageKeyTest do
  @moduledoc """
  Verifies that the cached metadata entry points key by the configured language
  so non-English libraries do not read English-cached entries, and libraries on
  different languages do not collide. See U4 of the TV-metadata-language plan.
  """
  use ExUnit.Case, async: false

  alias Mydia.Metadata
  alias Mydia.Metadata.Cache

  setup do
    Cache.clear()
    :ok
  end

  defp config(language) do
    %{
      type: :metadata_relay,
      base_url: "https://example.test",
      options: %{language: language, include_adult: false}
    }
  end

  describe "fetch_season_cached/4 cache key" do
    test "varies by the config's language so two languages don't collide" do
      es_key = Metadata.build_season_cache_key("100", 1, "es-ES", nil)
      en_key = Metadata.build_season_cache_key("100", 1, "en-US", nil)

      assert es_key != en_key

      Cache.put(es_key, :spanish_season)
      Cache.put(en_key, :english_season)

      # Each config reads its own language's entry (cache hit, no fetch).
      assert {:ok, :spanish_season} =
               Metadata.fetch_season_cached(config("es-ES"), "100", 1, [])

      assert {:ok, :english_season} =
               Metadata.fetch_season_cached(config("en-US"), "100", 1, [])
    end

    test "an explicit :language opt still overrides the config default" do
      es_key = Metadata.build_season_cache_key("100", 1, "es-ES", nil)
      Cache.put(es_key, :spanish_season)

      # Config says en-US, but the explicit opt wins and hits the es entry.
      assert {:ok, :spanish_season} =
               Metadata.fetch_season_cached(config("en-US"), "100", 1, language: "es-ES")
    end

    test "a bare config (no options.language) falls back to en-US" do
      en_key = Metadata.build_season_cache_key("100", 1, "en-US", nil)
      Cache.put(en_key, :english_season)

      bare_config = %{type: :metadata_relay, base_url: "https://example.test"}

      assert {:ok, :english_season} =
               Metadata.fetch_season_cached(bare_config, "100", 1, [])
    end
  end

  describe "fetch_by_id_cached/3 cache key" do
    test "varies by the config's language" do
      es_key = "fetch_by_id:metadata_relay:603:tv_show:es-ES::official"
      en_key = "fetch_by_id:metadata_relay:603:tv_show:en-US::official"

      Cache.put(es_key, :spanish_show)
      Cache.put(en_key, :english_show)

      assert {:ok, :spanish_show} =
               Metadata.fetch_by_id_cached(config("es-ES"), "603", media_type: :tv_show)

      assert {:ok, :english_show} =
               Metadata.fetch_by_id_cached(config("en-US"), "603", media_type: :tv_show)
    end

    # TVDB's orderings of one series describe the same episodes grouped
    # differently, so without the ordering in the key the second caller reads
    # the first caller's grouping and never notices: the payload is well formed,
    # just the wrong shape.
    test "varies by the requested season ordering" do
      official_key = "fetch_by_id:metadata_relay:603:tv_show:en-US::official"
      dvd_key = "fetch_by_id:metadata_relay:603:tv_show:en-US::dvd"

      Cache.put(official_key, :official_show)
      Cache.put(dvd_key, :dvd_show)

      assert {:ok, :dvd_show} =
               Metadata.fetch_by_id_cached(config("en-US"), "603",
                 media_type: :tv_show,
                 season_order: :dvd
               )

      # nil means "never asked" and resolves to the official ordering, so it
      # shares the key with an explicit :official rather than getting its own.
      assert {:ok, :official_show} =
               Metadata.fetch_by_id_cached(config("en-US"), "603",
                 media_type: :tv_show,
                 season_order: nil
               )
    end
  end
end
