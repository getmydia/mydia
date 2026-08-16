defmodule Mydia.Downloads.ReleaseValidator do
  @moduledoc """
  Validates release names to reject invalid/fake/hashed torrents before parsing.

  This module implements pre-filtering to catch known bad release patterns that
  should be rejected before attempting to match against library items. This prevents
  false matches and saves processing time on obviously invalid releases.

  ## Invalid Patterns

  1. **Hashed releases** - Release names containing long hex strings in brackets
     - Example: `[A1B2C3D4E5F6G7H8I9J0K1L2M3N4O5P6] Some Movie 2020`
     - These are obfuscated releases that are likely fake or malicious

  2. **Numeric-only titles** - Releases with only numbers and no meaningful text
     - Example: `123456789.1080p.BluRay.x264`
     - Real releases always have some alphanumeric title

  3. **Password-protected releases** - Releases requiring passwords
     - Example: `Password Protected Movie 2020 1080p`
     - Often scams or low-quality releases

  4. **Reversed patterns** - Strange reversed title formats
     - Example: `p0801.BluRay.1080p.x264`
     - Non-standard naming that indicates automated spam

  5. **Yenc patterns** - Usenet binary encoding patterns
     - Example: `yenc movie title`
     - These are raw usenet posts, not proper releases

  6. **Suspicious executable extensions** - Release name ends in an executable
     extension (.exe, .scr, .bat, .cmd, .com, .msi, .vbs, .js, .jar, .pif)
     - Example: `From.S04E05.1080p.WEB.h264-ETHEL.exe`
     - These are malware torrents disguised as 1080p video releases. A
       legitimate video release never carries an executable extension.

  ## Usage

      iex> ReleaseValidator.validate_release("The.Matrix.1999.1080p.BluRay.x264")
      {:ok, "The.Matrix.1999.1080p.BluRay.x264"}

      iex> ReleaseValidator.validate_release("[A1B2C3D4E5F6G7H8I9J0K1L2M3N4O5P6] Fake Movie")
      {:error, :hashed_release}

      iex> ReleaseValidator.validate_release("12345678.1080p.x264")
      {:error, :numeric_only_title}
  """

  require Logger

  @doc """
  Validates a release name against known bad patterns.

  Returns `{:ok, name}` if the release is valid,
  or `{:error, reason}` if it should be rejected.

  ## Rejection Reasons

  - `:hashed_release` - Contains long hex string in brackets
  - `:numeric_only_title` - Title has only numbers, no text
  - `:password_protected` - Requires password
  - `:reversed_pattern` - Strange reversed naming
  - `:yenc_pattern` - Raw usenet binary encoding
  - `:no_meaningful_content` - No extractable title content
  - `:suspicious_extension` - Release name ends in an executable extension
  - `:no_title` - Release has a nil title (malformed result)
  """
  @spec validate_release(String.t() | nil) :: {:ok, String.t()} | {:error, atom()}
  def validate_release(nil), do: {:error, :no_title}

  def validate_release(name) when is_binary(name) do
    cond do
      suspicious_extension?(name) ->
        Logger.warning("Rejecting release with suspicious executable extension: #{name}")
        {:error, :suspicious_extension}

      is_hashed_release?(name) ->
        Logger.debug("Rejecting hashed release: #{name}")
        {:error, :hashed_release}

      is_numeric_only?(name) ->
        Logger.debug("Rejecting numeric-only release: #{name}")
        {:error, :numeric_only_title}

      is_password_protected?(name) ->
        Logger.debug("Rejecting password-protected release: #{name}")
        {:error, :password_protected}

      is_reversed_pattern?(name) ->
        Logger.debug("Rejecting reversed pattern release: #{name}")
        {:error, :reversed_pattern}

      is_yenc_pattern?(name) ->
        Logger.debug("Rejecting yenc pattern release: #{name}")
        {:error, :yenc_pattern}

      has_no_meaningful_content?(name) ->
        Logger.debug("Rejecting release with no meaningful content: #{name}")
        {:error, :no_meaningful_content}

      true ->
        {:ok, name}
    end
  end

  ## Private Functions - Validation Patterns

  # Release filenames that end in a Windows executable extension are malware
  # — a legitimate 1080p video release never has a .exe extension. These show
  # up periodically from public indexers using real-looking release-group
  # names (e.g. "ETHEL") to slip past automatic-grab filters.
  @suspicious_extensions ~w(.exe .scr .bat .cmd .com .msi .vbs .js .jar .pif)

  defp suspicious_extension?(name) do
    trimmed = String.trim(name)

    # Check the final extension of both the raw name AND a tag-stripped form.
    # Public indexers mask a malware extension behind a trailing site tag
    # (e.g. "From.S04E05.1080p.WEB.h264-ETHEL.exe[tracker.org]"), where the raw
    # extension is ".org]" and the real ".exe" only surfaces once the tag is
    # removed. Checking the stripped form closes that bypass.
    [trimmed, strip_trailing_tags(trimmed)]
    |> Enum.any?(fn candidate ->
      candidate
      |> Path.extname()
      |> String.downcase()
      |> Kernel.in(@suspicious_extensions)
    end)
  end

  # Strip one or more trailing bracket tags ([...], 【...】, {...}) from a name.
  defp strip_trailing_tags(name) do
    name
    |> String.replace(~r/(?:\s*(?:\[[^\]]*\]|【[^】]*】|\{[^}]*\}))+\s*$/u, "")
    |> String.trim()
  end

  # Detects hashed releases with long hex strings in brackets
  # Example: [A1B2C3D4E5F6G7H8I9J0K1L2M3N4O5P6] Movie Title
  defp is_hashed_release?(name) do
    # Look for 24-32 character hex strings in brackets/parentheses
    Regex.match?(~r/[\[\(]([A-F0-9]{24,32})[\]\)]/i, name)
  end

  # Detects releases with only numbers in the title portion
  # Example: 123456.1080p.BluRay.x264
  defp is_numeric_only?(name) do
    # Extract the title portion (before year or quality markers)
    title_portion = extract_title_portion(name)

    # Check if title has only digits, dots, dashes, underscores
    # (no letters)
    title_portion != "" and String.match?(title_portion, ~r/^[\d\s\.\-_]+$/)
  end

  # Detects password-protected releases
  # Example: Password Protected Movie 2020 or Movie [PASSWORD]
  defp is_password_protected?(name) do
    name_lower = String.downcase(name)

    String.contains?(name_lower, "password") or
      String.contains?(name_lower, "passworded") or
      String.contains?(name_lower, "pass protected")
  end

  # Detects reversed/strange naming patterns
  # Example: p0801.Movie.Title.1080p
  defp is_reversed_pattern?(name) do
    # Pattern: starts with p followed by 3-4 digits
    Regex.match?(~r/^p\d{3,4}[\.\s\-_]/i, name)
  end

  # Detects yenc binary encoding patterns from usenet
  # Example: yenc Movie Title or [yenc] Something
  defp is_yenc_pattern?(name) do
    name_lower = String.downcase(name)
    String.contains?(name_lower, "yenc")
  end

  # Checks if the release has any meaningful textual content
  # After removing common noise, there should be some letters
  defp has_no_meaningful_content?(name) do
    # Remove common noise: brackets, quality, years, etc.
    cleaned =
      name
      |> String.replace(~r/\[[^\]]+\]/, "")
      |> String.replace(~r/\([^\)]+\)/, "")
      |> String.replace(~r/\b(19|20)\d{2}\b/, "")
      |> String.replace(~r/\b(480|720|1080|2160)p\b/i, "")
      |> String.replace(~r/\b(BluRay|WEB-?DL|WEBRip|HDTV|x264|x265|H\.?264|H\.?265)\b/i, "")
      |> String.trim()

    # After cleanup, check if there are any letters left
    not String.match?(cleaned, ~r/[a-zA-Z]{2,}/)
  end

  # Extracts the title portion before quality/year markers
  defp extract_title_portion(name) do
    # Split on common markers: year (1900-2099), resolution (480p, 720p, etc)
    parts =
      Regex.split(~r/\b(19|20)\d{2}\b|\b\d{3,4}p\b/i, name, parts: 2, include_captures: false)

    case parts do
      [title | _] -> String.trim(title)
      [] -> ""
    end
  end
end
