defmodule MydiaWeb.ImportMediaLive.Labels do
  @moduledoc """
  Translated labels and summary sentences for the grouped import review table.
  """

  use Gettext, backend: MydiaWeb.Gettext

  alias Mydia.Metadata.TvProvider

  def band_chip_label(:all), do: pgettext("import band", "All")
  def band_chip_label(:ready), do: pgettext("import band", "Ready")
  def band_chip_label(:needs_attention), do: pgettext("import band", "Needs attention")
  def band_chip_label(:no_match), do: pgettext("import band", "No match")
  def band_chip_label(:queued), do: pgettext("import band", "Queued")
  def band_chip_label(:ignored), do: pgettext("import band", "Ignored")

  # Two counts in one sentence: one whole-sentence msgid per group form, with
  # the file count driving the plural.
  def delete_summary(files, 1) do
    ngettext(
      "Permanently delete %{count} file in 1 group from disk? This cannot be undone.",
      "Permanently delete %{count} files in 1 group from disk? This cannot be undone.",
      files
    )
  end

  def delete_summary(files, groups) do
    ngettext(
      "Permanently delete %{count} file in %{groups} groups from disk? This cannot be undone.",
      "Permanently delete %{count} files in %{groups} groups from disk? This cannot be undone.",
      files,
      groups: groups
    )
  end

  def band_label(:ready), do: pgettext("import band badge", "ready")
  def band_label(:needs_attention), do: pgettext("import band badge", "needs attention")
  def band_label(:no_match), do: pgettext("import band badge", "no match")

  def suggestion_line(%{provider_id: nil}), do: gettext("No provider match")

  # A provider id with no title: rows staged before `stage_item_file/3` wrote
  # the show's title, and the leftovers `create_local_show/2` stamps local.
  # Both used to render an arrow pointing at nothing.
  def suggestion_line(%{provider_type: "local", suggested_title: title})
      when title in [nil, ""],
      do: gettext("→ Local show")

  def suggestion_line(%{suggested_title: title} = group) when title in [nil, ""],
    do:
      gettext("→ %{provider} %{id}",
        provider: provider_label(group.provider_type),
        id: group.provider_id
      )

  def suggestion_line(group) do
    year = if group.suggested_year, do: " (#{group.suggested_year})", else: ""
    "→ #{group.suggested_title}#{year}"
  end

  def provider_label(provider), do: TvProvider.label(provider) || gettext("Provider")

  # `ImportCandidateGroup` carries no persisted evidence trail (unlike the old
  # `ImportGroup.evidence` column) -- `provider_count` is the one disagreement
  # signal the aggregate itself can cheaply surface: more than one distinct
  # provider id among a group's candidates is exactly what nulls out
  # `min_confidence` and forces the group into `:needs_attention` (see
  # `Mydia.ImportCandidates.group_query/2`), so the badge explains why an
  # otherwise-matched-looking group still needs a look.
  def disagreement_label(%{provider_count: n}) when is_integer(n) and n > 1,
    do: ngettext("%{count} conflicting match", "%{count} conflicting matches", n)

  def disagreement_label(_), do: nil

  # One shared message is a group-level reason (no match, retries exhausted),
  # written to every row alike. Different messages are per-file reasons, and
  # each row shows its own.
  def group_error_label(%{distinct_error_count: distinct, error_count: count})
      when distinct > 1 and is_integer(count),
      do: ngettext("%{count} file couldn't import", "%{count} files couldn't import", count)

  def group_error_label(%{queue_error: error}), do: error
end
