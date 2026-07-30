defmodule Mydia.Downloads.Client.FailureCategory do
  @moduledoc """
  The shared vocabulary for *why* a download client reported a terminal
  failure (issue #237).

  Download clients report failure at wildly different granularities: TorBox
  gives a `download_state` string, AllDebrid a numeric `statusCode`,
  Premiumize a single `"error"` for everything. Each adapter collapses its
  native detail into one of the categories here, and this module owns the
  three renderings that vocabulary needs:

    * `slug/1` — the stable string written to `release_blacklist.failure_reason`
    * `label/1` — the human phrase shown in the admin UI and failure messages
    * `message/3` — the operator-facing sentence stored on the
      `download.failed` event

  Categories are deliberately *diagnostic only*. Nothing here influences
  whether a release is blacklisted or for how long — see the non-goals in
  `docs/superpowers/specs/2026-07-29-debrid-failure-detail-design.md`.

  `nil` is a valid input everywhere: it means "the client reported a failure
  but we could not classify it", which covers every non-debrid adapter today
  as well as any provider state we have not mapped. It renders as the
  pre-existing `"client_reported_failure"` slug so rows written before this
  module existed stay valid.
  """

  @type t :: :no_peers | :missing_files | :rejected_content | :provider_error

  # The slug used before this module existed. Retained as the fallback so
  # historical rows keep rendering and the admin filter keeps working.
  @fallback_slug "client_reported_failure"

  @default_message "Download failed in client"

  @labels %{
    no_peers: "no peers",
    missing_files: "missing files",
    rejected_content: "rejected content",
    provider_error: "provider error"
  }

  # Slug -> label, resolved at compile time. Deliberately NOT
  # `String.to_atom/1` at runtime: slugs arrive from the database, and
  # atom conversion on stored input is a memory-leak vector.
  @slug_labels @labels
               |> Map.new(fn {category, label} -> {Atom.to_string(category), label} end)
               |> Map.put(@fallback_slug, "client reported failure")

  @doc """
  The string written to `release_blacklist.failure_reason`.
  """
  @spec slug(t() | nil) :: String.t()
  def slug(nil), do: @fallback_slug
  def slug(category) when is_map_key(@labels, category), do: Atom.to_string(category)

  @doc """
  The human phrase for a category atom, or for a slug read back out of the
  database. Unrecognised slugs are humanized rather than raising, so a row
  written by a future version doesn't break the admin page.
  """
  @spec label(t() | String.t() | nil) :: String.t()
  def label(nil), do: Map.fetch!(@slug_labels, @fallback_slug)

  def label(category) when is_atom(category) do
    Map.get_lazy(@labels, category, fn -> humanize(Atom.to_string(category)) end)
  end

  def label(slug) when is_binary(slug) do
    Map.get_lazy(@slug_labels, slug, fn -> humanize(slug) end)
  end

  @doc """
  The operator-facing failure sentence, e.g.
  `"torbox reported missing files: missingFiles"`.

  With neither a category nor a detail there is nothing to add, so this
  returns the constant used before #237 rather than an emptier sentence.

  When there is a detail but no category — an adapter surfaced a native
  detail string it couldn't classify — the category label is dropped
  rather than rendered as the generic "client reported failure", which
  would read as a redundant "reported client reported failure: ...".
  """
  @spec message(String.t() | nil, t() | nil, String.t() | nil) :: String.t()
  def message(client, category, detail) do
    subject = if blank?(client), do: "Download client", else: client

    cond do
      is_nil(category) and blank?(detail) ->
        @default_message

      is_nil(category) ->
        "#{subject} reported: #{detail}"

      blank?(detail) ->
        "#{subject} reported #{label(category)}"

      true ->
        "#{subject} reported #{label(category)}: #{detail}"
    end
  end

  defp humanize(slug), do: String.replace(slug, "_", " ")

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false
end
