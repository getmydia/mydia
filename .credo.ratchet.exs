# Loaded only by `mix mydia.ratchet`, never by plain `mix credo`. These two checks
# are judged against the merge base, not the whole tree: see Mydia.Ratchet and
# "Ratchets" in CONTRIBUTING.md.
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      },
      strict: true,
      color: false,
      checks: %{
        enabled: [
          {Credo.Check.Refactor.CyclomaticComplexity, []},
          {Credo.Check.Refactor.Nesting, []}
        ]
      }
    }
  ]
}
