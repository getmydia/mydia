defmodule MetadataRelayWeb.ErrorHTML do
  @moduledoc """
  HTML error pages, for callers whose `Accept` header prefers HTML.

  `MetadataRelayWeb.Layouts` holds the 404 and 500 pages but no others, and it
  cannot serve as the error view itself: any other status (a 400 for a
  malformed body, a 413) raised inside the error renderer and became an empty
  500. Statuses without a page get their plain status message.
  """

  alias MetadataRelay.IngestRejection
  alias MetadataRelayWeb.Layouts

  def render(template, assigns) do
    case assigns do
      %{conn: conn, reason: reason} -> IngestRejection.record_parser_error(conn, reason)
      _ -> :ok
    end

    case template do
      "404.html" -> Layouts."404"(assigns)
      "500.html" -> Layouts."500"(assigns)
      _ -> Phoenix.Controller.status_message_from_template(template)
    end
  end
end
