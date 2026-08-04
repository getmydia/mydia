defmodule Mydia.Downloads.ReleaseIntake do
  @moduledoc """
  The sole release-name parse entry point for the Downloads context.

  Composes `Mydia.Downloads.ReleaseValidator` ahead of
  `Mydia.Library.ReleaseParser` so the validation gate (fake / malicious /
  hashed / password / yenc / reversed / executable-extension releases) is never
  bypassed before a release name reaches the matcher.

  `ReleaseParser` itself never rejects input — it always returns a
  `%ParsedFileInfo{}`, sometimes typed `:unknown`. This module converts that
  always-a-struct shape back into the reject-or-parse contract the download
  callers depend on:

  - validator rejection → `{:error, reason}` (the validator's specific reason)
  - `:unknown` type with no usable title → `{:error, :unable_to_parse}`
  - `:unknown` type with a usable title → `{:ok, info}` so the matcher's
    title-similarity path can still produce a *suggestion*
  - otherwise → `{:ok, %ParsedFileInfo{}}`

  Downloads callers must use this function rather than calling
  `Library.ReleaseParser` directly for the initial parse. The one exception is
  `Mydia.Indexers.ReleaseRanker`, which already runs the validator over its
  result list separately and parses titles directly afterward.
  """

  alias Mydia.Downloads.ReleaseValidator
  alias Mydia.Library.ReleaseParser
  alias Mydia.Library.Structs.ParsedFileInfo

  @doc """
  Validate then parse a release name.

  Returns `{:ok, %ParsedFileInfo{}}` for a usable parse, or `{:error, reason}`
  when the validator rejects the name or the parser cannot extract anything
  usable. See the module doc for the full contract.
  """
  @spec parse_release(String.t()) :: {:ok, ParsedFileInfo.t()} | {:error, atom()}
  def parse_release(name) when is_binary(name) do
    # Validate the ORIGINAL name first — the validator detects hashed releases by
    # hex strings in brackets, so cleaning must not run before it. The validator's
    # suspicious-extension check is tag-aware (it strips trailing bracket tags),
    # so a `.exe` masked by a trailing tag is still rejected here.
    with {:ok, validated} <- ReleaseValidator.validate_release(name) do
      validated
      |> clean_torrent_name()
      |> ReleaseParser.parse()
      |> classify_parse_result()
    end
  end

  # Strip torrent-specific noise the file-oriented ReleaseParser does not handle:
  # tracker-site bracket tags ([47BT], [Ex-torrenty.org], [bitsearch.to]), CJK
  # bracket blocks (【...】), and CJK season markers (第6季, 第四季). Without this
  # these tokens bleed into the parsed title and degrade matching for releases
  # from CJK / private-tracker sources. Ported from the retired TorrentParser.
  defp clean_torrent_name(name) do
    name
    |> String.replace(~r/【[^】]*】\s*/u, "")
    |> String.replace(~r/\[[^\]]+\]\s*/u, "")
    |> String.replace(~r/\{[^\}]+\}\s*/u, "")
    |> String.replace(~r/第\d+季\s*/u, "")
    |> String.replace(~r/第[一二三四五六七八九十]+季\s*/u, "")
    |> String.trim()
  end

  # A release whose title did not parse cannot be title-matched against the
  # library whatever type was inferred for it. ReleaseParser.infer_media_type/4
  # returns :movie on a year or quality token alone, so a titleless :movie is
  # reachable and previously fell through the catch-all clause into matching.
  defp classify_parse_result(%ParsedFileInfo{type: :unknown} = info) do
    if usable_title?(info.title) do
      {:ok, info}
    else
      {:error, :unable_to_parse}
    end
  end

  defp classify_parse_result(%ParsedFileInfo{} = info) do
    if usable_title?(info.title) do
      {:ok, info}
    else
      {:error, :missing_title}
    end
  end

  defp usable_title?(title) when is_binary(title), do: String.trim(title) != ""
  defp usable_title?(_), do: false
end
