defmodule Mydia.Settings.QualityProfilePresetsTest do
  use ExUnit.Case, async: true

  alias Mydia.Settings.QualityProfilePresets

  describe "list_presets/0" do
    test "returns a list of all presets" do
      presets = QualityProfilePresets.list_presets()

      assert is_list(presets)
      refute Enum.empty?(presets)

      # Verify preset structure
      first_preset = List.first(presets)
      assert Map.has_key?(first_preset, :id)
      assert Map.has_key?(first_preset, :name)
      assert Map.has_key?(first_preset, :category)
      assert Map.has_key?(first_preset, :description)
      assert Map.has_key?(first_preset, :tags)
      assert Map.has_key?(first_preset, :source)
      assert Map.has_key?(first_preset, :profile_data)
    end

    test "all presets have valid profile data" do
      presets = QualityProfilePresets.list_presets()

      for preset <- presets do
        assert Map.has_key?(preset.profile_data, :name)
        assert Map.has_key?(preset.profile_data, :upgrades_allowed)
        assert Map.has_key?(preset.profile_data, :quality_standards)
        assert is_list(preset.profile_data.quality_standards.preferred_resolutions)
        assert preset.profile_data.quality_standards.preferred_resolutions != []
      end
    end

    test "includes TRaSH Guides presets" do
      presets = QualityProfilePresets.list_presets()

      trash_presets =
        Enum.filter(presets, fn preset ->
          preset.category == :trash_guides
        end)

      assert length(trash_presets) >= 6
    end

    test "includes storage-optimized presets" do
      presets = QualityProfilePresets.list_presets()

      storage_presets =
        Enum.filter(presets, fn preset ->
          preset.category == :storage_optimized
        end)

      assert length(storage_presets) >= 3
    end

    test "includes use-case presets" do
      presets = QualityProfilePresets.list_presets()

      use_case_presets =
        Enum.filter(presets, fn preset ->
          preset.category == :use_case
        end)

      assert length(use_case_presets) >= 3
    end
  end

  describe "list_presets_by_category/1" do
    test "filters presets by trash_guides category" do
      presets = QualityProfilePresets.list_presets_by_category(:trash_guides)

      assert is_list(presets)
      assert Enum.all?(presets, fn preset -> preset.category == :trash_guides end)
      assert length(presets) >= 6
    end

    test "filters presets by storage_optimized category" do
      presets = QualityProfilePresets.list_presets_by_category(:storage_optimized)

      assert is_list(presets)
      assert Enum.all?(presets, fn preset -> preset.category == :storage_optimized end)
      assert length(presets) >= 3
    end

    test "filters presets by use_case category" do
      presets = QualityProfilePresets.list_presets_by_category(:use_case)

      assert is_list(presets)
      assert Enum.all?(presets, fn preset -> preset.category == :use_case end)
      assert length(presets) >= 3
    end

    test "returns all presets for :all category" do
      presets = QualityProfilePresets.list_presets_by_category(:all)

      assert is_list(presets)
      assert length(presets) == length(QualityProfilePresets.list_presets())
    end

    test "returns empty list for non-existent category" do
      presets = QualityProfilePresets.list_presets_by_category(:nonexistent)

      assert presets == []
    end
  end

  describe "list_presets_by_tags/1" do
    test "filters presets by single tag" do
      presets = QualityProfilePresets.list_presets_by_tags(["4k"])

      assert is_list(presets)
      assert Enum.all?(presets, fn preset -> "4k" in preset.tags end)
      assert presets != []
    end

    test "filters presets by multiple tags (OR logic)" do
      presets = QualityProfilePresets.list_presets_by_tags(["4k", "hdr"])

      assert is_list(presets)

      assert Enum.all?(presets, fn preset ->
               "4k" in preset.tags or "hdr" in preset.tags
             end)

      assert presets != []
    end

    test "returns empty list for non-existent tag" do
      presets = QualityProfilePresets.list_presets_by_tags(["nonexistent-tag"])

      assert presets == []
    end

    test "returns empty list for empty tag list" do
      presets = QualityProfilePresets.list_presets_by_tags([])

      assert presets == []
    end
  end

  describe "get_preset/1" do
    test "returns preset by ID" do
      {:ok, preset} = QualityProfilePresets.get_preset("trash-hd-bluray-web")

      assert preset.id == "trash-hd-bluray-web"
      assert preset.name == "TRaSH - HD Bluray + WEB"
      assert preset.category == :trash_guides
      assert preset.source == "TRaSH Guides"
    end

    test "returns error for non-existent preset ID" do
      assert {:error, :not_found} = QualityProfilePresets.get_preset("nonexistent")
    end

    test "returned preset has valid profile data" do
      {:ok, preset} = QualityProfilePresets.get_preset("trash-hd-bluray-web")

      profile_data = preset.profile_data
      assert profile_data.name == "TRaSH - HD Bluray + WEB"
      assert is_list(profile_data.quality_standards.preferred_resolutions)
      assert is_boolean(profile_data.upgrades_allowed)
      assert is_map(profile_data.quality_standards)
    end
  end

  describe "preset quality standards validation" do
    test "all TRaSH Guides presets have valid quality standards" do
      presets = QualityProfilePresets.list_presets_by_category(:trash_guides)

      for preset <- presets do
        standards = preset.profile_data.quality_standards

        # Check that standards contain expected keys
        assert is_map(standards)

        # Validate resolution fields if present
        if Map.has_key?(standards, :preferred_resolutions) do
          assert is_list(standards.preferred_resolutions)
          assert Enum.all?(standards.preferred_resolutions, &is_binary/1)
        end

        # Validate video codecs if present
        if Map.has_key?(standards, :preferred_video_codecs) do
          assert is_list(standards.preferred_video_codecs)
          assert Enum.all?(standards.preferred_video_codecs, &is_binary/1)
        end

        # Validate sources if present
        if Map.has_key?(standards, :preferred_sources) do
          assert is_list(standards.preferred_sources)
          assert Enum.all?(standards.preferred_sources, &is_binary/1)
        end
      end
    end

    test "storage-optimized presets have size constraints" do
      presets = QualityProfilePresets.list_presets_by_category(:storage_optimized)

      for preset <- presets do
        standards = preset.profile_data.quality_standards

        # Storage-optimized presets should have size constraints
        assert Map.has_key?(standards, :movie_min_size_mb) or
                 Map.has_key?(standards, :movie_max_size_mb) or
                 Map.has_key?(standards, :episode_min_size_mb) or
                 Map.has_key?(standards, :episode_max_size_mb)
      end
    end

    test "4K presets include HDR formats" do
      presets = QualityProfilePresets.list_presets_by_tags(["4k"])

      for preset <- presets do
        standards = preset.profile_data.quality_standards

        # 4K presets should specify HDR formats
        assert Map.has_key?(standards, :hdr_formats)
        assert is_list(standards.hdr_formats)
        assert standards.hdr_formats != []
      end
    end
  end

  describe "preset metadata" do
    test "all presets have source attribution" do
      presets = QualityProfilePresets.list_presets()

      for preset <- presets do
        assert is_binary(preset.source)
        assert String.length(preset.source) > 0
      end
    end

    test "all presets have descriptions" do
      presets = QualityProfilePresets.list_presets()

      for preset <- presets do
        assert is_binary(preset.description)
        assert String.length(preset.description) > 20
      end
    end

    test "all presets have at least one tag" do
      presets = QualityProfilePresets.list_presets()

      for preset <- presets do
        assert is_list(preset.tags)
        assert preset.tags != []
        assert Enum.all?(preset.tags, &is_binary/1)
      end
    end

    test "TRaSH Guides presets have source URLs" do
      presets = QualityProfilePresets.list_presets_by_category(:trash_guides)

      for preset <- presets do
        assert is_binary(preset.source_url)
        assert String.starts_with?(preset.source_url, "https://trash-guides.info/")
      end
    end
  end
end
