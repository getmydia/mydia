defmodule Mydia.Library.ImportCandidateGroup do
  @moduledoc """
  A read model for one anchor folder's worth of durable import candidates.

  Unlike the old `Mydia.Library.ImportGroup`, this is never persisted. It is
  materialized on every read by `Mydia.ImportCandidates.group_query/2`
  aggregating `import_candidates` rows at query time, so there is no rollup
  row to keep in sync with the files it describes -- the group simply stops
  existing the moment its last candidate is dismissed, promoted, or deleted.

  `id` is set to `anchor_key` rather than a generated id, so a LiveView
  `stream/3` built from these has a stable identity across pages without a
  database-assigned key. `anchor_key` is a normalized folder name and can
  contain spaces, Unicode, or other characters that are not valid in a CSS/DOM
  id, so templates must render `dom_id/1` for the HTML `id` attribute rather
  than the raw `anchor_key` or `id` field.
  """

  @enforce_keys [:id, :anchor_key, :library_path_id, :file_count]
  defstruct [
    :id,
    :anchor_key,
    :library_path_id,
    :display_title,
    :file_count,
    :provider_type,
    :provider_id,
    :suggested_title,
    :suggested_year,
    :media_type,
    :min_confidence,
    :provider_count,
    :dismissed?
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          anchor_key: String.t(),
          library_path_id: binary(),
          display_title: String.t() | nil,
          file_count: non_neg_integer(),
          provider_type: String.t() | nil,
          provider_id: String.t() | nil,
          suggested_title: String.t() | nil,
          suggested_year: integer() | nil,
          media_type: String.t() | nil,
          min_confidence: float() | nil,
          provider_count: non_neg_integer() | nil,
          dismissed?: boolean() | nil
        }

  @doc """
  A DOM-safe id for this group, for use as an HTML/CSS element id.

  `anchor_key` is a normalized folder name (lowercased, punctuation stripped)
  but can still contain spaces and non-ASCII letters, neither of which is
  safe inside a bare CSS selector. URL-safe base64 (no padding) is stable and
  collision-free, but its first output character is not guaranteed to be a
  letter: it is derived from the leading byte of `anchor_key`, and a
  Unicode-leading anchor (a non-Latin show or folder name) can produce a
  byte whose encoding starts with a digit. A digit-leading id is not a valid
  CSS identifier and is not safe to use unescaped in a `#id` selector or a
  `phx-update="stream"` DOM id. The `"g"` prefix guarantees a letter always
  leads, so the result never needs escaping.
  """
  @spec dom_id(t()) :: String.t()
  def dom_id(%__MODULE__{anchor_key: key}) do
    "g" <> Base.url_encode64(key, padding: false)
  end
end
