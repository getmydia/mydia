defmodule Mydia.Indexers.Cardigann.LiveCheck.Outcome do
  @moduledoc """
  One definition's result in a live compatibility sweep (`Mydia.Indexers.Cardigann.LiveCheck`).
  """

  @type bucket ::
          :ok
          | :ok_empty_query
          | :cloudflare
          | :unreachable
          | :blocked_page
          | :rows_dropped
          | :no_rows
          | :parse_error
          | :template_error
          | :http_4xx
          | :grab_failed
          | :unsupported_definition

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          bucket: bucket(),
          base_url: String.t() | nil,
          rows: non_neg_integer(),
          rows_empty_query: non_neg_integer() | nil,
          dropped: non_neg_integer(),
          grab: String.t() | nil,
          error: String.t() | nil,
          ms: non_neg_integer()
        }

  @derive Jason.Encoder
  defstruct [
    :id,
    :name,
    :bucket,
    :base_url,
    :rows_empty_query,
    :grab,
    :error,
    rows: 0,
    dropped: 0,
    ms: 0
  ]

  @doc "True for the two buckets that count as working."
  @spec working?(t()) :: boolean()
  def working?(%__MODULE__{bucket: bucket}), do: bucket in [:ok, :ok_empty_query]
end
