defmodule MydiaWeb.AdminIndexersLive.ErrorMessages do
  @moduledoc """
  Operator-facing text for errors raised by the Indexers page: definition sync
  and FlareSolverr transport failures.
  """

  @spec format_sync_error(term()) :: String.t()
  def format_sync_error(:rate_limit_exceeded),
    do: "GitHub API rate limit exceeded. Try again later."

  def format_sync_error(:not_found), do: "Repository or definitions path not found."
  def format_sync_error({:unexpected_status, status}), do: "Unexpected HTTP status: #{status}"
  def format_sync_error(reason) when is_binary(reason), do: reason
  def format_sync_error(reason), do: inspect(reason)

  # Transport reasons are usually atoms (:econnrefused, :timeout) but can be
  # tuples, such as a TLS alert, which string interpolation cannot render.
  @spec format_transport_reason(term()) :: String.t()
  def format_transport_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  def format_transport_reason(reason), do: inspect(reason)
end
