defmodule MetadataRelayWeb.ErrorJSON do
  @moduledoc """
  JSON bodies for errors raised before a route answers, chiefly
  `Plug.Parsers.ParseError` from the endpoint's parser.

  The endpoint used to render errors only through `MetadataRelayWeb.Layouts`,
  which has no 400 template, so a malformed JSON body crashed the error
  renderer and the caller got an empty 500. This module answers API callers;
  `MetadataRelayWeb.ErrorHTML` answers callers that ask for HTML.
  """

  alias MetadataRelay.IngestRejection

  def render(template, %{conn: conn, reason: reason}) do
    IngestRejection.record_parser_error(conn, reason)
    body(template, reason)
  end

  def render(template, _assigns), do: body(template, nil)

  defp body(_template, %Plug.Parsers.ParseError{}),
    do: %{error: "Invalid JSON", message: "Request body must be valid JSON"}

  defp body(_template, %Plug.Parsers.RequestTooLargeError{}),
    do: %{error: "Request body too large"}

  defp body(template, _reason),
    do: %{error: Phoenix.Controller.status_message_from_template(template)}
end
