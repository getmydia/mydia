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
  - `qualities` - List of allowed quality strings (resolutions, sources, etc.)
  - `upgrades_allowed` - Whether automatic quality upgrades are allowed
  - `upgrade_until_quality` - Maximum quality to upgrade to (if upgrades enabled)
  - `rules` - Map containing additional rules (size limits, preferred sources, etc.)

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
        qualities: ["360p", "480p", "576p", "720p", "1080p", "2160p"],
        upgrades_allowed: true,
        upgrade_until_quality: "2160p",
        rules: %{
          min_size_mb: nil,
          max_size_mb: nil,
          preferred_sources: [],
          description: "Any quality, no size limits. Maximizes availability."
        }
      },
      %{
        name: "SD",
        qualities: ["480p", "576p"],
        upgrades_allowed: true,
        upgrade_until_quality: "576p",
        rules: %{
          min_size_mb: nil,
          max_size_mb: 2048,
          preferred_sources: ["DVD", "DVDRip", "SDTV"],
          description: "Standard Definition up to 480p/DVD quality. Limited to 2GB."
        }
      },
      %{
        name: "HD-720p",
        qualities: ["720p"],
        upgrades_allowed: false,
        upgrade_until_quality: nil,
        rules: %{
          min_size_mb: 1024,
          max_size_mb: 5120,
          preferred_sources: ["BluRay", "WEB-DL", "HDTV"],
          description: "720p HD content. Balanced quality and file size (1-5GB)."
        }
      },
      %{
        name: "HD-1080p",
        qualities: ["1080p"],
        upgrades_allowed: false,
        upgrade_until_quality: nil,
        rules: %{
          min_size_mb: 2048,
          max_size_mb: 15360,
          preferred_sources: ["BluRay", "WEB-DL"],
          description: "1080p Full HD content. Standard high quality (2-15GB)."
        }
      },
      %{
        name: "Full HD",
        qualities: ["1080p"],
        upgrades_allowed: false,
        upgrade_until_quality: nil,
        rules: %{
          min_size_mb: 4096,
          max_size_mb: 20480,
          preferred_sources: ["REMUX", "BluRay"],
          description: "Strict 1080p with high-quality sources only (4-20GB)."
        }
      },
      %{
        name: "Remux-1080p",
        qualities: ["1080p"],
        upgrades_allowed: false,
        upgrade_until_quality: nil,
        rules: %{
          min_size_mb: 20480,
          max_size_mb: 40960,
          preferred_sources: ["REMUX"],
          description: "Lossless 1080p REMUX releases. Premium quality (20-40GB)."
        }
      },
      %{
        name: "4K/UHD",
        qualities: ["2160p"],
        upgrades_allowed: false,
        upgrade_until_quality: nil,
        rules: %{
          min_size_mb: 15360,
          max_size_mb: 81920,
          preferred_sources: ["REMUX", "BluRay", "WEB-DL"],
          description: "Ultra HD 2160p/4K content. Maximum quality (15-80GB)."
        }
      },
      %{
        name: "Remux-2160p",
        qualities: ["2160p"],
        upgrades_allowed: false,
        upgrade_until_quality: nil,
        rules: %{
          min_size_mb: 40960,
          max_size_mb: 102400,
          preferred_sources: ["REMUX"],
          description: "Lossless 4K REMUX releases. Ultimate quality (40-100GB)."
        }
      }
    ]
  end
end
