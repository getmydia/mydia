defmodule MydiaWeb.Languages do
  @moduledoc """
  Display names for the ISO 639-1 language codes the UI offers.

  This is presentation data rather than domain data: providers and the metadata
  relay all speak raw codes, and the only consumers of the names are web
  surfaces (Discover's language filter and the subtitle search modal).
  """

  @all [
    {"en", "English"},
    {"ja", "Japanese"},
    {"ko", "Korean"},
    {"es", "Spanish"},
    {"fr", "French"},
    {"de", "German"},
    {"it", "Italian"},
    {"pt", "Portuguese"},
    {"zh", "Chinese"},
    {"hi", "Hindi"},
    {"ru", "Russian"},
    {"ar", "Arabic"},
    {"th", "Thai"},
    {"tr", "Turkish"},
    {"pl", "Polish"},
    {"nl", "Dutch"},
    {"sv", "Swedish"},
    {"da", "Danish"},
    {"no", "Norwegian"},
    {"fi", "Finnish"}
  ]

  # The languages that get a permanent chip in the subtitle search modal. The
  # rest live behind its dropdown.
  @common ~w(en es fr de it pt ja zh)

  @names Map.new(@all)

  @doc "Every offered language as `{code, display_name}`, in menu order."
  @spec all() :: [{String.t(), String.t()}]
  def all, do: @all

  @doc "The subset shown as always-visible chips, in display order."
  @spec common() :: [{String.t(), String.t()}]
  def common, do: Enum.map(@common, fn code -> {code, name(code)} end)

  @doc "Display name for a code, falling back to the code itself when unknown."
  @spec name(String.t()) :: String.t()
  def name(code), do: Map.get(@names, code, code)
end
