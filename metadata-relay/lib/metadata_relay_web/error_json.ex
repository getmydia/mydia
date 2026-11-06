defmodule MetadataRelayWeb.ErrorJSON do
  @moduledoc """
  Bodies for errors raised before a route answers, chiefly
  `Plug.Parsers.ParseError` from the endpoint's parser.

  Before this module the endpoint rendered errors only through
  `MetadataRelayWeb.Layouts`, which has no 400 template, so a malformed JSON
  body crashed the error renderer and the caller got an empty 500. Listed
  first in `render_errors`, it answers API callers; browsers asking for HTML
  still get `Layouts`.
  """

  alias MetadataRelay.IngestRejection

  def render(_template, %{reason: %Plug.Parsers.ParseError{}, conn: conn}) do
    IngestRejection.record(conn, :not_json, 400)
    %{error: "Invalid JSON", message: "Request body must be valid JSON"}
  end

  def render(_template, %{reason: %Plug.Parsers.RequestTooLargeError{}, conn: conn}) do
    IngestRejection.record(conn, :too_large, 413)
    %{error: "Request body too large"}
  end

  def render(template, _assigns) do
    %{error: Phoenix.Controller.status_message_from_template(template)}
  end
end
