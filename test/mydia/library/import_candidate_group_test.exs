defmodule Mydia.Library.ImportCandidateGroupTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.ImportCandidateGroup

  defp group(anchor_key) do
    %ImportCandidateGroup{
      id: anchor_key,
      anchor_key: anchor_key,
      library_path_id: Ecto.UUID.generate(),
      file_count: 1
    }
  end

  describe "dom_id/1" do
    test "always starts with a letter, even when the unprefixed encoding would not" do
      # A plain-ASCII anchor key (e.g. "2024 collection") can never produce a
      # digit-leading `Base.url_encode64/2` output on its own: the first
      # output character is derived from the top 6 bits of the first input
      # byte, and every ASCII byte's top 6 bits land in the letter range of
      # the base64 alphabet. A Unicode-leading anchor key can, though --
      # "Ѐ" (Cyrillic Ѐ) is a real anchor_key byte, per this module's own
      # moduledoc ("can hold spaces, Unicode, or other characters"), and
      # encodes with a leading "0" absent the "g" prefix `dom_id/1` adds.
      dom_id = ImportCandidateGroup.dom_id(group("Ѐ collection"))

      assert dom_id =~ ~r/\A[A-Za-z]/
    end

    test "is stable and collision-free across different anchor keys" do
      a = ImportCandidateGroup.dom_id(group("show one"))
      b = ImportCandidateGroup.dom_id(group("show two"))

      assert a != b
      assert a == ImportCandidateGroup.dom_id(group("show one"))
    end
  end
end
