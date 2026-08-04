defmodule Mydia.Settings.DefaultQualityProfiles do
  @moduledoc """
  Defines default quality profiles that are automatically created on application startup.

  These profiles provide sensible defaults for common use cases and are created
  idempotently if they don't already exist in the database.
  """

  @doc """
  Returns the list of default quality profile definitions.

  Each profile includes:
  - `name` - Unique name for the profile
  - `quality_standards.preferred_resolutions` - List of preferred resolution strings
  - `upgrades_allowed` - Whether automatic quality upgrades are allowed
  - `upgrade_until_score` - Score cutoff to upgrade to (if upgrades enabled)
  - `description` - Human-readable description of the profile

  ## Profile Descriptions

  - **Any** - Accepts any quality, no size limits. For maximum availability.
  - **SD** - Standard Definition (480p, DVD). Under 2GB file size.
  - **HD-720p** - 720p HD content, 1-5GB file size. Balanced quality/size.
  - **HD-1080p** - 1080p Full HD content, 2-15GB. Standard high quality.
  - **Full HD** - Strict 1080p only with higher quality sources, 4-20GB.
  - **Remux-1080p** - Lossless 1080p REMUX releases, 20-40GB. Premium quality.
  - **4K/UHD** - Ultra HD 2160p content, 15-80GB. Maximum quality.
  - **Remux-2160p** - Lossless 4K REMUX releases, 40-100GB. Ultimate quality.
  """
  @spec defaults() :: [map()]
  def defaults do
    [
      %{
        name: "Any",
        upgrades_allowed: true,
        upgrade_until_score: 95,
        description: "Any quality, no size limits. Maximizes availability.",
        quality_standards: %{
          excluded_sources: ["CAM", "Telesync", "Telecine", "Screener", "Workprint"],
          preferred_resolutions: ["360p", "480p", "576p", "720p", "1080p", "2160p"]
        }
      },
      %{
        name: "SD",
        upgrades_allowed: true,
        upgrade_until_score: 45,
        description: "Standard Definition up to 480p/DVD quality. Limited to 2GB.",
        quality_standards: %{
          excluded_sources: ["CAM", "Telesync", "Telecine", "Screener", "Workprint"],
          max_resolution: "576p",
          preferred_resolutions: ["480p", "576p"],
          preferred_sources: ["DVD", "DVDRip", "SDTV"],
          movie_max_size_mb: 2048,
          episode_max_size_mb: 1024
        }
      },
      %{
        name: "HD-720p",
        upgrades_allowed: false,
        description: "720p HD content. Balanced quality and file size (1-5GB).",
        quality_standards: %{
          excluded_sources: ["CAM", "Telesync", "Telecine", "Screener", "Workprint"],
          min_resolution: "720p",
          max_resolution: "720p",
          preferred_resolutions: ["720p"],
          preferred_sources: ["BluRay", "WEB-DL", "HDTV"],
          preferred_video_codecs: ["h264", "h265"],
          movie_min_size_mb: 1024,
          movie_max_size_mb: 5120,
          episode_min_size_mb: 512,
          episode_max_size_mb: 2560
        }
      },
      %{
        name: "HD-1080p",
        upgrades_allowed: false,
        description: "1080p Full HD content. Standard high quality (2-15GB).",
        quality_standards: %{
          excluded_sources: ["CAM", "Telesync", "Telecine", "Screener", "Workprint"],
          min_resolution: "1080p",
          max_resolution: "1080p",
          preferred_resolutions: ["1080p"],
          preferred_sources: ["BluRay", "WEB-DL"],
          preferred_video_codecs: ["h265", "h264"],
          movie_min_size_mb: 2048,
          movie_max_size_mb: 15360,
          episode_min_size_mb: 1024,
          episode_max_size_mb: 7680
        }
      },
      %{
        name: "Full HD",
        upgrades_allowed: false,
        description: "Strict 1080p with high-quality sources only (4-20GB).",
        quality_standards: %{
          excluded_sources: ["CAM", "Telesync", "Telecine", "Screener", "Workprint"],
          min_resolution: "1080p",
          max_resolution: "1080p",
          preferred_resolutions: ["1080p"],
          preferred_sources: ["REMUX", "BluRay"],
          preferred_video_codecs: ["h265", "h264"],
          movie_min_size_mb: 4096,
          movie_max_size_mb: 20480,
          episode_min_size_mb: 2048,
          episode_max_size_mb: 10240
        }
      },
      %{
        name: "Remux-1080p",
        upgrades_allowed: false,
        description: "Lossless 1080p REMUX releases. Premium quality (20-40GB).",
        quality_standards: %{
          excluded_sources: ["CAM", "Telesync", "Telecine", "Screener", "Workprint"],
          min_resolution: "1080p",
          max_resolution: "1080p",
          preferred_resolutions: ["1080p"],
          preferred_sources: ["REMUX"],
          preferred_video_codecs: ["h265", "h264"],
          preferred_audio_codecs: ["truehd", "dts-hd", "atmos"],
          movie_min_size_mb: 20480,
          movie_max_size_mb: 40960,
          episode_min_size_mb: 10240,
          episode_max_size_mb: 20480
        }
      },
      %{
        name: "4K/UHD",
        upgrades_allowed: false,
        description: "Ultra HD 2160p/4K content. Maximum quality (15-80GB).",
        quality_standards: %{
          excluded_sources: ["CAM", "Telesync", "Telecine", "Screener", "Workprint"],
          min_resolution: "2160p",
          max_resolution: "2160p",
          preferred_resolutions: ["2160p"],
          preferred_sources: ["REMUX", "BluRay", "WEB-DL"],
          preferred_video_codecs: ["h265", "av1"],
          preferred_audio_codecs: ["atmos", "truehd", "dts-hd"],
          hdr_formats: ["dolby_vision", "hdr10+", "hdr10"],
          movie_min_size_mb: 15360,
          movie_max_size_mb: 81920,
          episode_min_size_mb: 7680,
          episode_max_size_mb: 40960
        }
      },
      %{
        name: "Remux-2160p",
        upgrades_allowed: false,
        description: "Lossless 4K REMUX releases. Ultimate quality (40-100GB).",
        quality_standards: %{
          excluded_sources: ["CAM", "Telesync", "Telecine", "Screener", "Workprint"],
          min_resolution: "2160p",
          max_resolution: "2160p",
          preferred_resolutions: ["2160p"],
          preferred_sources: ["REMUX"],
          preferred_video_codecs: ["h265", "av1"],
          preferred_audio_codecs: ["atmos", "truehd", "dts-hd"],
          hdr_formats: ["dolby_vision", "hdr10+", "hdr10"],
          movie_min_size_mb: 40960,
          movie_max_size_mb: 102_400,
          episode_min_size_mb: 20480,
          episode_max_size_mb: 51200
        }
      }
    ]
  end
end
