defmodule Mydia.Settings.QualityProfilePresets do
  @moduledoc """
  Curated quality profile presets based on TRaSH Guides, Profilarr/Dictionarry, and community best practices.

  This module provides a library of pre-configured quality profiles that users can
  browse and import to quickly set up optimal quality settings without manual configuration.

  ## Preset Categories

  - **TRaSH Guides** - Community-vetted profiles based on TRaSH Guides recommendations
  - **Profilarr** - Dictionarry database presets (compatible with Radarr/Sonarr Profilarr tool)
  - **Storage-optimized** - Profiles optimized for different storage constraints
  - **Use-case specific** - Profiles tailored for specific use cases

  ## Preset Structure

  Each preset includes:
  - `id` - Unique identifier for the preset
  - `name` - Display name
  - `category` - Category for grouping (trash_guides, profilarr, storage_optimized, use_case)
  - `description` - Detailed description of the preset
  - `tags` - List of tags for filtering (4k, hdr, anime, web, remux, etc.)
  - `source` - Source of the preset (TRaSH Guides, Profilarr/Dictionarry, Mydia, etc.)
  - `source_url` - URL to the source documentation if available
  - `updated_at` - Last update date
  - `profile_data` - The actual quality profile configuration
  """

  @doc """
  Returns all available quality profile presets.

  ## Examples

      iex> list_presets()
      [
        %{
          id: "trash-hd-bluray-web",
          name: "TRaSH - HD Bluray + WEB",
          category: :trash_guides,
          ...
        }
      ]
  """
  @spec list_presets() :: [map()]
  def list_presets do
    trash_guides_presets() ++
      profilarr_presets() ++ storage_optimized_presets() ++ use_case_presets()
  end

  @doc """
  Returns presets filtered by category.

  ## Categories

  - `:trash_guides` - TRaSH Guides community presets
  - `:profilarr` - Profilarr/Dictionarry database presets
  - `:storage_optimized` - Storage-conscious presets
  - `:use_case` - Use-case specific presets
  - `:all` - All presets (default)

  ## Examples

      iex> list_presets_by_category(:trash_guides)
      [%{id: "trash-hd-bluray-web", ...}, ...]

      iex> list_presets_by_category(:profilarr)
      [%{id: "profilarr-1080p-quality", ...}, ...]
  """
  @spec list_presets_by_category(atom()) :: [map()]
  def list_presets_by_category(:all), do: list_presets()

  def list_presets_by_category(category) do
    list_presets()
    |> Enum.filter(&(&1.category == category))
  end

  @doc """
  Returns presets filtered by tags.

  ## Examples

      iex> list_presets_by_tags(["4k", "hdr"])
      [%{id: "trash-uhd-bluray-web", ...}, ...]
  """
  @spec list_presets_by_tags([String.t()]) :: [map()]
  def list_presets_by_tags(tags) when is_list(tags) do
    list_presets()
    |> Enum.filter(fn preset ->
      Enum.any?(tags, &(&1 in preset.tags))
    end)
  end

  @doc """
  Gets a specific preset by ID.

  ## Examples

      iex> get_preset("trash-hd-bluray-web")
      {:ok, %{id: "trash-hd-bluray-web", ...}}

      iex> get_preset("nonexistent")
      {:error, :not_found}
  """
  @spec get_preset(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_preset(preset_id) do
    case Enum.find(list_presets(), &(&1.id == preset_id)) do
      nil -> {:error, :not_found}
      preset -> {:ok, preset}
    end
  end

  ## TRaSH Guides Presets
  ## Based on https://trash-guides.info/

  defp trash_guides_presets do
    [
      # HD Bluray + WEB (Movies)
      %{
        id: "trash-hd-bluray-web",
        name: "TRaSH - HD Bluray + WEB",
        category: :trash_guides,
        description:
          "High-quality HD encodes prioritizing Blu-ray and streaming sources. Best for standard HD displays with moderate storage capacity. File size: 6-15 GB for 1080p movies.",
        tags: ["1080p", "hd", "bluray", "web", "movies"],
        source: "TRaSH Guides",
        source_url: "https://trash-guides.info/Radarr/radarr-setup-quality-profiles/",
        updated_at: ~D[2025-11-24],
        profile_data: %{
          name: "TRaSH - HD Bluray + WEB",
          upgrades_allowed: true,
          upgrade_until_score: 85,
          description:
            "TRaSH Guides: High-quality HD encodes for Blu-ray and streaming sources (6-15 GB)",
          quality_standards: %{
            min_resolution: "720p",
            max_resolution: "1080p",
            preferred_resolutions: ["1080p"],
            preferred_sources: ["BluRay", "WEB-DL"],
            preferred_video_codecs: ["h265", "h264"],
            preferred_audio_codecs: ["dts-hd", "ac3", "aac"],
            movie_min_size_mb: 6144,
            movie_max_size_mb: 15360,
            episode_min_size_mb: 1024,
            episode_max_size_mb: 3072
          }
        }
      },

      # UHD Bluray + WEB (Movies)
      %{
        id: "trash-uhd-bluray-web",
        name: "TRaSH - UHD Bluray + WEB",
        category: :trash_guides,
        description:
          "Ultra high-definition encodes with HDR support. Best for 4K displays and HDR-capable equipment. File size: 20-60 GB for 2160p movies.",
        tags: ["4k", "2160p", "uhd", "hdr", "bluray", "web", "movies"],
        source: "TRaSH Guides",
        source_url: "https://trash-guides.info/Radarr/radarr-setup-quality-profiles/",
        updated_at: ~D[2025-11-24],
        profile_data: %{
          name: "TRaSH - UHD Bluray + WEB",
          upgrades_allowed: true,
          upgrade_until_score: 95,
          description: "TRaSH Guides: Ultra HD 4K encodes with HDR support (20-60 GB)",
          quality_standards: %{
            min_resolution: "2160p",
            max_resolution: "2160p",
            preferred_resolutions: ["2160p"],
            preferred_sources: ["BluRay", "WEB-DL"],
            preferred_video_codecs: ["h265", "av1"],
            preferred_audio_codecs: ["atmos", "truehd", "dts-hd"],
            hdr_formats: ["dolby_vision", "hdr10+", "hdr10"],
            movie_min_size_mb: 20480,
            movie_max_size_mb: 61440,
            episode_min_size_mb: 5120,
            episode_max_size_mb: 15360
          }
        }
      },

      # Remux + WEB 1080p (Movies)
      %{
        id: "trash-remux-web-1080p",
        name: "TRaSH - Remux + WEB 1080p",
        category: :trash_guides,
        description:
          "High-fidelity 1080p releases with lossless audio. Best for users prioritizing audio quality with standard displays. File size: 20-40 GB for 1080p movies.",
        tags: ["1080p", "remux", "web", "lossless", "movies"],
        source: "TRaSH Guides",
        source_url: "https://trash-guides.info/Radarr/radarr-setup-quality-profiles/",
        updated_at: ~D[2025-11-24],
        profile_data: %{
          name: "TRaSH - Remux + WEB 1080p",
          upgrades_allowed: true,
          upgrade_until_score: 85,
          description: "TRaSH Guides: 1080p with lossless audio (20-40 GB)",
          quality_standards: %{
            min_resolution: "1080p",
            max_resolution: "1080p",
            preferred_resolutions: ["1080p"],
            preferred_sources: ["REMUX", "WEB-DL"],
            preferred_video_codecs: ["h265", "h264"],
            preferred_audio_codecs: ["truehd", "dts-hd", "atmos"],
            movie_min_size_mb: 20480,
            movie_max_size_mb: 40960,
            episode_min_size_mb: 5120,
            episode_max_size_mb: 10240
          }
        }
      },

      # Remux + WEB 2160p (Movies)
      %{
        id: "trash-remux-web-2160p",
        name: "TRaSH - Remux + WEB 2160p",
        category: :trash_guides,
        description:
          "Highest quality 4K releases with lossless audio and HDR. Best for users with premium equipment demanding maximum quality. File size: 40-100 GB for 2160p movies.",
        tags: ["4k", "2160p", "remux", "web", "hdr", "lossless", "movies"],
        source: "TRaSH Guides",
        source_url: "https://trash-guides.info/Radarr/radarr-setup-quality-profiles/",
        updated_at: ~D[2025-11-24],
        profile_data: %{
          name: "TRaSH - Remux + WEB 2160p",
          upgrades_allowed: true,
          upgrade_until_score: 95,
          description: "TRaSH Guides: 4K with lossless audio and HDR (40-100 GB)",
          quality_standards: %{
            min_resolution: "2160p",
            max_resolution: "2160p",
            preferred_resolutions: ["2160p"],
            preferred_sources: ["REMUX", "WEB-DL"],
            preferred_video_codecs: ["h265", "av1"],
            preferred_audio_codecs: ["atmos", "truehd", "dts-hd"],
            hdr_formats: ["dolby_vision", "hdr10+", "hdr10"],
            movie_min_size_mb: 40960,
            movie_max_size_mb: 102_400,
            episode_min_size_mb: 10240,
            episode_max_size_mb: 25600
          }
        }
      },

      # WEB-1080p (TV Shows)
      %{
        id: "trash-web-1080p",
        name: "TRaSH - WEB-1080p",
        category: :trash_guides,
        description:
          "Sweet spot between quality and size for TV content. Prefers 720p/1080p web releases with standard quality-to-size balance. Best for regular TV viewing.",
        tags: ["1080p", "web", "tv", "series"],
        source: "TRaSH Guides",
        source_url: "https://trash-guides.info/Sonarr/sonarr-setup-quality-profiles/",
        updated_at: ~D[2025-11-24],
        profile_data: %{
          name: "TRaSH - WEB-1080p",
          upgrades_allowed: true,
          upgrade_until_score: 85,
          description: "TRaSH Guides: Web releases optimized for TV shows (1-3 GB per episode)",
          quality_standards: %{
            min_resolution: "720p",
            max_resolution: "1080p",
            preferred_resolutions: ["1080p"],
            preferred_sources: ["WEB-DL", "WEBRip"],
            preferred_video_codecs: ["h264", "h265"],
            preferred_audio_codecs: ["aac", "ac3"],
            episode_min_size_mb: 1024,
            episode_max_size_mb: 3072,
            movie_min_size_mb: 4096,
            movie_max_size_mb: 12288
          }
        }
      },

      # WEB-2160p (TV Shows)
      %{
        id: "trash-web-2160p",
        name: "TRaSH - WEB-2160p",
        category: :trash_guides,
        description:
          "4K/UHD content with HDR support for TV shows. Targets WEB-2160p with Dolby Vision/HDR10+ options. Best for premium TV viewing on 4K displays.",
        tags: ["4k", "2160p", "web", "hdr", "tv", "series"],
        source: "TRaSH Guides",
        source_url: "https://trash-guides.info/Sonarr/sonarr-setup-quality-profiles/",
        updated_at: ~D[2025-11-24],
        profile_data: %{
          name: "TRaSH - WEB-2160p",
          upgrades_allowed: true,
          upgrade_until_score: 95,
          description:
            "TRaSH Guides: 4K web releases with HDR for TV shows (5-15 GB per episode)",
          quality_standards: %{
            min_resolution: "2160p",
            max_resolution: "2160p",
            preferred_resolutions: ["2160p"],
            preferred_sources: ["WEB-DL", "WEBRip"],
            preferred_video_codecs: ["h265", "av1"],
            preferred_audio_codecs: ["atmos", "dts-hd", "ac3"],
            hdr_formats: ["dolby_vision", "hdr10+", "hdr10"],
            episode_min_size_mb: 5120,
            episode_max_size_mb: 15360,
            movie_min_size_mb: 20480,
            movie_max_size_mb: 61440
          }
        }
      }
    ]
  end

  ## Profilarr/Dictionarry Presets
  ## Based on https://github.com/Dictionarry-Hub/database
  ## These presets are compatible with the Profilarr tool for Radarr/Sonarr

  defp profilarr_presets do
    [
      # 720p Quality - Transparent x264 encodes
      %{
        id: "profilarr-720p-quality",
        name: "Profilarr - 720p Quality",
        category: :profilarr,
        description:
          "Golden Popcorn Performance Index: Transparent x264 720p encodes. Prioritizes quality over compression efficiency. Best for standard displays with limited bandwidth. Fallback: 480p WEB-DL → DVD.",
        tags: ["720p", "quality", "x264", "h264", "movies", "tv"],
        source: "Profilarr/Dictionarry",
        source_url: "https://github.com/Dictionarry-Hub/database",
        updated_at: ~D[2025-11-25],
        profile_data: %{
          name: "Profilarr - 720p Quality",
          upgrades_allowed: true,
          upgrade_until_score: 60,
          description:
            "Profilarr: Transparent x264 720p encodes using GPPI scoring (original language only)",
          quality_standards: %{
            min_resolution: "480p",
            max_resolution: "720p",
            preferred_resolutions: ["720p"],
            preferred_sources: ["BluRay", "WEB-DL", "WEBRip"],
            # x264/h264 only - excludes h265, AV1, VP9
            preferred_video_codecs: ["h264"],
            preferred_audio_codecs: ["flac", "dts-hd", "ac3", "aac"],
            movie_min_size_mb: 2048,
            movie_max_size_mb: 8192,
            episode_min_size_mb: 512,
            episode_max_size_mb: 2048
          }
        }
      },

      # 1080p Quality - Transparent x264 encodes (highest x264 quality)
      %{
        id: "profilarr-1080p-quality",
        name: "Profilarr - 1080p Quality",
        category: :profilarr,
        description:
          "Golden Popcorn Performance Index: Transparent x264 1080p encodes. Maximum quality for x264 codec with preferred streaming sources. Bans h265/AV1 for compatibility. Fallback: 720p → 480p → DVD.",
        tags: ["1080p", "quality", "x264", "h264", "movies", "tv", "streaming"],
        source: "Profilarr/Dictionarry",
        source_url: "https://github.com/Dictionarry-Hub/database",
        updated_at: ~D[2025-11-25],
        profile_data: %{
          name: "Profilarr - 1080p Quality",
          upgrades_allowed: true,
          upgrade_until_score: 85,
          description:
            "Profilarr: Transparent x264 1080p encodes using GPPI scoring (original language only)",
          quality_standards: %{
            min_resolution: "480p",
            max_resolution: "1080p",
            preferred_resolutions: ["1080p"],
            preferred_sources: ["BluRay", "WEB-DL", "WEBRip"],
            # x264/h264 only - bans h265, AV1, VP9, Remux, HDR
            preferred_video_codecs: ["h264"],
            preferred_audio_codecs: ["flac", "dts-hd", "ac3", "aac"],
            movie_min_size_mb: 4096,
            movie_max_size_mb: 15360,
            episode_min_size_mb: 1024,
            episode_max_size_mb: 3072
          }
        }
      },

      # 1080p Quality HDR - Transparent x265 HDR encodes
      %{
        id: "profilarr-1080p-quality-hdr",
        name: "Profilarr - 1080p Quality HDR",
        category: :profilarr,
        description:
          "Golden Popcorn Performance Index: Transparent x265 HDR 1080p encodes. Prioritizes HDR content with h265 compression. Includes UHD BluRay fallback for HDR sources. Best for HDR-capable 1080p displays.",
        tags: ["1080p", "quality", "x265", "h265", "hdr", "movies", "tv"],
        source: "Profilarr/Dictionarry",
        source_url: "https://github.com/Dictionarry-Hub/database",
        updated_at: ~D[2025-11-25],
        profile_data: %{
          name: "Profilarr - 1080p Quality HDR",
          upgrades_allowed: true,
          upgrade_until_score: 85,
          description:
            "Profilarr: Transparent x265 HDR 1080p encodes using GPPI scoring (original language only)",
          quality_standards: %{
            min_resolution: "480p",
            max_resolution: "1080p",
            preferred_resolutions: ["1080p"],
            preferred_sources: ["BluRay", "WEB-DL", "WEBRip"],
            # x265 for HDR efficiency - bans x264 WEB, AV1, Remux
            preferred_video_codecs: ["h265"],
            preferred_audio_codecs: ["flac", "dts-hd", "atmos", "ac3", "aac"],
            hdr_formats: ["dolby_vision", "hdr10+", "hdr10"],
            movie_min_size_mb: 6144,
            movie_max_size_mb: 20480,
            episode_min_size_mb: 1536,
            episode_max_size_mb: 4096
          }
        }
      },

      # 1080p Balanced - Consistent WEB-DLs
      %{
        id: "profilarr-1080p-balanced",
        name: "Profilarr - 1080p Balanced",
        category: :profilarr,
        description:
          "Targets consistent, immutable 1080p WEB-DLs using streaming source and audio format scoring. Prioritizes major streaming platforms (AMZN, ATVP, DSNP). Best balance of quality and availability.",
        tags: ["1080p", "balanced", "web", "x264", "h264", "movies", "tv", "streaming"],
        source: "Profilarr/Dictionarry",
        source_url: "https://github.com/Dictionarry-Hub/database",
        updated_at: ~D[2025-11-25],
        profile_data: %{
          name: "Profilarr - 1080p Balanced",
          upgrades_allowed: true,
          upgrade_until_score: 85,
          description:
            "Profilarr: Consistent 1080p WEB-DLs with streaming source prioritization (original language only)",
          quality_standards: %{
            min_resolution: "480p",
            max_resolution: "1080p",
            preferred_resolutions: ["1080p"],
            # Prioritizes WEB sources over BluRay for consistency
            preferred_sources: ["WEB-DL", "BluRay", "WEBRip"],
            # x264/h264 for compatibility - bans h265, AV1, HDR, Remux
            preferred_video_codecs: ["h264"],
            preferred_audio_codecs: ["flac", "dts-hd", "ac3", "aac"],
            movie_min_size_mb: 3072,
            movie_max_size_mb: 12288,
            episode_min_size_mb: 768,
            episode_max_size_mb: 2560
          }
        }
      },

      # 1080p Efficient - x265 for storage efficiency
      %{
        id: "profilarr-1080p-efficient",
        name: "Profilarr - 1080p Efficient",
        category: :profilarr,
        description:
          "Targets consistent, immutable 1080p WEB-DLs with h265/x265 for storage efficiency. Smaller file sizes while maintaining quality. Best for storage-conscious users with modern playback devices.",
        tags: ["1080p", "efficient", "x265", "h265", "web", "movies", "tv", "storage"],
        source: "Profilarr/Dictionarry",
        source_url: "https://github.com/Dictionarry-Hub/database",
        updated_at: ~D[2025-11-25],
        profile_data: %{
          name: "Profilarr - 1080p Efficient",
          upgrades_allowed: true,
          upgrade_until_score: 85,
          description:
            "Profilarr: Efficient 1080p x265 WEB-DLs for smaller file sizes (original language only)",
          quality_standards: %{
            min_resolution: "480p",
            max_resolution: "1080p",
            preferred_resolutions: ["1080p"],
            preferred_sources: ["WEB-DL", "BluRay", "WEBRip"],
            # x265/h265 for efficiency - bans x264, AV1, VP9, Remux
            preferred_video_codecs: ["h265"],
            preferred_audio_codecs: ["ac3", "aac", "flac"],
            movie_min_size_mb: 2048,
            movie_max_size_mb: 8192,
            episode_min_size_mb: 512,
            episode_max_size_mb: 1536
          }
        }
      },

      # 1080p Compact - Maximum compression with h265
      %{
        id: "profilarr-1080p-compact",
        name: "Profilarr - 1080p Compact",
        category: :profilarr,
        description:
          "Targets 1080p BluRay and WEB x265 encodes for maximum storage efficiency. Heavily penalizes x264 and uncompressed formats. Best for limited storage with h265-compatible playback devices.",
        tags: ["1080p", "compact", "x265", "h265", "storage", "movies", "tv"],
        source: "Profilarr/Dictionarry",
        source_url: "https://github.com/Dictionarry-Hub/database",
        updated_at: ~D[2025-11-25],
        profile_data: %{
          name: "Profilarr - 1080p Compact",
          upgrades_allowed: true,
          upgrade_until_score: 85,
          description:
            "Profilarr: Compact 1080p x265 encodes for maximum storage efficiency (original language only)",
          quality_standards: %{
            min_resolution: "480p",
            max_resolution: "1080p",
            preferred_resolutions: ["1080p"],
            preferred_sources: ["WEB-DL", "BluRay", "WEBRip"],
            # x265/h265 only - bans x264, Remux, lossless audio
            preferred_video_codecs: ["h265"],
            # Lossy audio only for smaller sizes
            preferred_audio_codecs: ["ac3", "aac"],
            movie_min_size_mb: 1536,
            movie_max_size_mb: 6144,
            episode_min_size_mb: 384,
            episode_max_size_mb: 1024
          }
        }
      },

      # 1080p Remux - Lossless quality
      %{
        id: "profilarr-1080p-remux",
        name: "Profilarr - 1080p Remux",
        category: :profilarr,
        description:
          "High-quality lossless 1080p copies with premium audio. Prioritizes Remux and UHD BluRay sources. Includes HDR/DV support. Best for audiophiles and quality purists with ample storage.",
        tags: ["1080p", "remux", "lossless", "hdr", "movies", "tv", "quality"],
        source: "Profilarr/Dictionarry",
        source_url: "https://github.com/Dictionarry-Hub/database",
        updated_at: ~D[2025-11-25],
        profile_data: %{
          name: "Profilarr - 1080p Remux",
          upgrades_allowed: true,
          upgrade_until_score: 85,
          description:
            "Profilarr: Lossless 1080p Remux with premium audio (original language only)",
          quality_standards: %{
            min_resolution: "480p",
            max_resolution: "1080p",
            preferred_resolutions: ["1080p"],
            # Remux first, then encoded BluRay, then WEB
            preferred_sources: ["REMUX", "BluRay", "WEB-DL"],
            preferred_video_codecs: ["h265", "h264"],
            # Lossless audio priority
            preferred_audio_codecs: ["truehd", "dts-hd", "atmos", "flac", "ac3"],
            hdr_formats: ["dolby_vision", "hdr10+", "hdr10"],
            movie_min_size_mb: 20480,
            movie_max_size_mb: 45056,
            episode_min_size_mb: 5120,
            episode_max_size_mb: 12288
          }
        }
      },

      # 2160p Quality - Transparent x265 4K encodes
      %{
        id: "profilarr-2160p-quality",
        name: "Profilarr - 2160p Quality",
        category: :profilarr,
        description:
          "Encode Efficiency Index: Transparent x265 4K encodes at 55% ratio. Best quality-to-size for 4K content with HDR support. Fallback hierarchy: 2160p → 1080p → 720p → DVD.",
        tags: ["4k", "2160p", "quality", "x265", "h265", "hdr", "movies", "tv"],
        source: "Profilarr/Dictionarry",
        source_url: "https://github.com/Dictionarry-Hub/database",
        updated_at: ~D[2025-11-25],
        profile_data: %{
          name: "Profilarr - 2160p Quality",
          upgrades_allowed: true,
          upgrade_until_score: 95,
          description:
            "Profilarr: Transparent x265 4K encodes using EEI scoring (original language only)",
          quality_standards: %{
            min_resolution: "480p",
            max_resolution: "2160p",
            preferred_resolutions: ["2160p", "1080p"],
            preferred_sources: ["BluRay", "WEB-DL", "WEBRip"],
            # x265 for 4K efficiency - bans h264/x264 at 2160p, AV1, VP9, Remux
            preferred_video_codecs: ["h265"],
            preferred_audio_codecs: ["truehd", "dts-hd", "atmos", "flac", "ac3", "aac"],
            hdr_formats: ["dolby_vision", "hdr10+", "hdr10"],
            movie_min_size_mb: 15360,
            movie_max_size_mb: 51200,
            episode_min_size_mb: 4096,
            episode_max_size_mb: 12288
          }
        }
      },

      # 2160p Balanced - Consistent 4K WEB-DLs
      %{
        id: "profilarr-2160p-balanced",
        name: "Profilarr - 2160p Balanced",
        category: :profilarr,
        description:
          "Targets consistent, immutable 2160p WEB-DLs with lossy audio. Prioritizes streaming platforms for 4K availability. Best balance of 4K quality and practical file sizes.",
        tags: ["4k", "2160p", "balanced", "web", "h265", "movies", "tv", "streaming"],
        source: "Profilarr/Dictionarry",
        source_url: "https://github.com/Dictionarry-Hub/database",
        updated_at: ~D[2025-11-25],
        profile_data: %{
          name: "Profilarr - 2160p Balanced",
          upgrades_allowed: true,
          upgrade_until_score: 95,
          description:
            "Profilarr: Consistent 2160p WEB-DLs with streaming source prioritization (original language only)",
          quality_standards: %{
            min_resolution: "480p",
            max_resolution: "2160p",
            preferred_resolutions: ["2160p", "1080p"],
            # WEB sources for 4K streaming content
            preferred_sources: ["WEB-DL", "BluRay", "WEBRip"],
            # h265 only - bans h264, AV1, VP9, Remux
            preferred_video_codecs: ["h265"],
            # Lossy audio for balanced sizes
            preferred_audio_codecs: ["flac", "dts-hd", "ac3", "aac"],
            hdr_formats: ["dolby_vision", "hdr10+", "hdr10"],
            movie_min_size_mb: 10240,
            movie_max_size_mb: 40960,
            episode_min_size_mb: 3072,
            episode_max_size_mb: 10240
          }
        }
      },

      # 2160p Efficient - Storage-efficient 4K with HEVC
      %{
        id: "profilarr-2160p-efficient",
        name: "Profilarr - 2160p Efficient",
        category: :profilarr,
        description:
          "Targets consistent, immutable 2160p WEB-DLs with HEVC/x265 for storage efficiency. Smaller 4K file sizes while maintaining visual quality. Best for storage-conscious 4K users.",
        tags: ["4k", "2160p", "efficient", "x265", "h265", "web", "storage", "movies", "tv"],
        source: "Profilarr/Dictionarry",
        source_url: "https://github.com/Dictionarry-Hub/database",
        updated_at: ~D[2025-11-25],
        profile_data: %{
          name: "Profilarr - 2160p Efficient",
          upgrades_allowed: true,
          upgrade_until_score: 95,
          description:
            "Profilarr: Efficient 2160p HEVC WEB-DLs for smaller 4K file sizes (original language only)",
          quality_standards: %{
            min_resolution: "480p",
            max_resolution: "2160p",
            preferred_resolutions: ["2160p", "1080p"],
            preferred_sources: ["WEB-DL", "BluRay", "WEBRip"],
            # HEVC for maximum 4K efficiency
            preferred_video_codecs: ["h265"],
            # Lossy audio for smaller sizes
            preferred_audio_codecs: ["ac3", "aac", "flac"],
            hdr_formats: ["dolby_vision", "hdr10+", "hdr10"],
            movie_min_size_mb: 8192,
            movie_max_size_mb: 30720,
            episode_min_size_mb: 2048,
            episode_max_size_mb: 8192
          }
        }
      },

      # 2160p Remux - Lossless 4K quality
      %{
        id: "profilarr-2160p-remux",
        name: "Profilarr - 2160p Remux",
        category: :profilarr,
        description:
          "High-quality lossless 4K copies of UHD BluRays. Maximum quality with Atmos/TrueHD audio and full HDR/DV support. Best for premium home theater setups with extensive storage.",
        tags: ["4k", "2160p", "remux", "lossless", "hdr", "dolby_vision", "atmos", "movies", "tv"],
        source: "Profilarr/Dictionarry",
        source_url: "https://github.com/Dictionarry-Hub/database",
        updated_at: ~D[2025-11-25],
        profile_data: %{
          name: "Profilarr - 2160p Remux",
          upgrades_allowed: true,
          upgrade_until_score: 95,
          description:
            "Profilarr: Lossless 4K UHD Remux with premium audio and HDR (original language only)",
          quality_standards: %{
            min_resolution: "480p",
            max_resolution: "2160p",
            preferred_resolutions: ["2160p", "1080p"],
            # Remux first, then quality encodes
            preferred_sources: ["REMUX", "BluRay", "WEB-DL"],
            preferred_video_codecs: ["h265"],
            # Lossless audio priority
            preferred_audio_codecs: ["atmos", "truehd", "dts-hd", "flac"],
            hdr_formats: ["dolby_vision", "hdr10+", "hdr10"],
            movie_min_size_mb: 40960,
            movie_max_size_mb: 102_400,
            episode_min_size_mb: 10240,
            episode_max_size_mb: 25600
          }
        }
      }
    ]
  end

  ## Storage-Optimized Presets

  defp storage_optimized_presets do
    [
      # Compact
      %{
        id: "storage-compact",
        name: "Storage - Compact",
        category: :storage_optimized,
        description:
          "Optimized for limited storage. Lower bitrates and smaller file sizes while maintaining watchable quality. File size: 1-4 GB for 1080p movies, 300-800 MB per episode.",
        tags: ["720p", "1080p", "compact", "storage", "small"],
        source: "Mydia",
        source_url: nil,
        updated_at: ~D[2025-11-24],
        profile_data: %{
          name: "Storage - Compact",
          upgrades_allowed: false,
          description:
            "Compact file sizes for limited storage (1-4 GB movies, 300-800 MB episodes)",
          quality_standards: %{
            max_resolution: "1080p",
            preferred_resolutions: ["720p", "1080p"],
            preferred_sources: ["WEB-DL", "WEBRip"],
            preferred_video_codecs: ["h265", "av1"],
            preferred_audio_codecs: ["aac"],
            movie_min_size_mb: 1024,
            movie_max_size_mb: 4096,
            episode_min_size_mb: 300,
            episode_max_size_mb: 800
          }
        }
      },

      # Balanced
      %{
        id: "storage-balanced",
        name: "Storage - Balanced",
        category: :storage_optimized,
        description:
          "Balanced quality vs size tradeoff. Good quality while being storage-conscious. File size: 4-10 GB for 1080p movies, 800-2 GB per episode.",
        tags: ["720p", "1080p", "balanced", "storage"],
        source: "Mydia",
        source_url: nil,
        updated_at: ~D[2025-11-24],
        profile_data: %{
          name: "Storage - Balanced",
          upgrades_allowed: true,
          upgrade_until_score: 85,
          description: "Balanced quality and size (4-10 GB movies, 800-2 GB episodes)",
          quality_standards: %{
            min_resolution: "720p",
            max_resolution: "1080p",
            preferred_resolutions: ["1080p"],
            preferred_sources: ["BluRay", "WEB-DL"],
            preferred_video_codecs: ["h265", "h264"],
            preferred_audio_codecs: ["ac3", "aac"],
            movie_min_size_mb: 4096,
            movie_max_size_mb: 10240,
            episode_min_size_mb: 800,
            episode_max_size_mb: 2048
          }
        }
      },

      # Archival
      %{
        id: "storage-archival",
        name: "Storage - Archival",
        category: :storage_optimized,
        description:
          "Maximum quality retention for long-term archival. Prioritizes lossless sources and high bitrates. File size: 30-80 GB for 1080p movies.",
        tags: ["1080p", "2160p", "archival", "remux", "lossless"],
        source: "Mydia",
        source_url: nil,
        updated_at: ~D[2025-11-24],
        profile_data: %{
          name: "Storage - Archival",
          upgrades_allowed: true,
          upgrade_until_score: 95,
          description: "Maximum quality for archival (30-80 GB movies)",
          quality_standards: %{
            min_resolution: "1080p",
            preferred_resolutions: ["2160p", "1080p"],
            preferred_sources: ["REMUX", "BluRay"],
            preferred_video_codecs: ["h265", "av1", "h264"],
            preferred_audio_codecs: ["atmos", "truehd", "dts-hd"],
            hdr_formats: ["dolby_vision", "hdr10+", "hdr10"],
            movie_min_size_mb: 30720,
            movie_max_size_mb: 81920,
            episode_min_size_mb: 8192,
            episode_max_size_mb: 20480
          }
        }
      }
    ]
  end

  ## Use-Case Specific Presets

  defp use_case_presets do
    [
      # Streaming
      %{
        id: "usecase-streaming",
        name: "Use Case - Streaming",
        category: :use_case,
        description:
          "Optimized for streaming over the internet. Web codecs with moderate bitrates for smooth streaming. File size: 2-8 GB for 1080p movies.",
        tags: ["streaming", "web", "720p", "1080p"],
        source: "Mydia",
        source_url: nil,
        updated_at: ~D[2025-11-24],
        profile_data: %{
          name: "Use Case - Streaming",
          upgrades_allowed: true,
          upgrade_until_score: 85,
          description: "Optimized for streaming (2-8 GB movies)",
          quality_standards: %{
            min_resolution: "720p",
            max_resolution: "1080p",
            preferred_resolutions: ["1080p", "720p"],
            preferred_sources: ["WEB-DL", "WEBRip"],
            preferred_video_codecs: ["h264", "h265"],
            preferred_audio_codecs: ["aac", "ac3"],
            movie_min_size_mb: 2048,
            movie_max_size_mb: 8192,
            episode_min_size_mb: 512,
            episode_max_size_mb: 2048
          }
        }
      },

      # Local Playback
      %{
        id: "usecase-local-playback",
        name: "Use Case - Local Playback",
        category: :use_case,
        description:
          "High quality for local playback without streaming constraints. Accepts any codec with high bitrates. File size: 10-40 GB for 1080p movies.",
        tags: ["local", "high-quality", "1080p", "2160p"],
        source: "Mydia",
        source_url: nil,
        updated_at: ~D[2025-11-24],
        profile_data: %{
          name: "Use Case - Local Playback",
          upgrades_allowed: true,
          upgrade_until_score: 95,
          description: "High quality for local playback (10-40 GB movies)",
          quality_standards: %{
            min_resolution: "1080p",
            preferred_resolutions: ["1080p", "2160p"],
            preferred_sources: ["BluRay", "REMUX"],
            movie_min_size_mb: 10240,
            movie_max_size_mb: 40960,
            episode_min_size_mb: 2560,
            episode_max_size_mb: 10240
          }
        }
      },

      # Mobile
      %{
        id: "usecase-mobile",
        name: "Use Case - Mobile",
        category: :use_case,
        description:
          "Optimized for mobile devices. Smaller sizes with h264 compatibility for broad device support. File size: 500 MB-2 GB for 720p movies.",
        tags: ["mobile", "720p", "h264", "small", "compatible"],
        source: "Mydia",
        source_url: nil,
        updated_at: ~D[2025-11-24],
        profile_data: %{
          name: "Use Case - Mobile",
          upgrades_allowed: false,
          description: "Mobile-friendly sizes and codecs (500 MB-2 GB movies)",
          quality_standards: %{
            max_resolution: "720p",
            preferred_resolutions: ["720p", "480p"],
            preferred_sources: ["WEB-DL", "WEBRip"],
            preferred_video_codecs: ["h264"],
            preferred_audio_codecs: ["aac"],
            movie_min_size_mb: 512,
            movie_max_size_mb: 2048,
            episode_min_size_mb: 200,
            episode_max_size_mb: 500
          }
        }
      }
    ]
  end
end
