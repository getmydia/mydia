%{
  configs: [
    %{
      name: "default",
      files: %{
        included: [
          "lib/",
          "src/",
          "test/",
          "web/",
          "apps/*/lib/",
          "apps/*/src/",
          "apps/*/test/",
          "apps/*/web/"
        ],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      },
      plugins: [],
      requires: [],
      strict: false,
      parse_timeout: 5000,
      color: true,
      checks: %{
        enabled: [
          ## Consistency Checks - things that should be consistent in code
          {Credo.Check.Consistency.ExceptionNames, []},
          {Credo.Check.Consistency.LineEndings, []},
          {Credo.Check.Consistency.ParameterPatternMatching, []},
          {Credo.Check.Consistency.SpaceAroundOperators, []},
          {Credo.Check.Consistency.SpaceInParentheses, []},
          {Credo.Check.Consistency.TabsOrSpaces, []},

          ## Design Checks - suggestions for improving code structure
          # Disabled with intent: aliasing repeated fully-qualified module
          # references is a subjective style preference the team does not
          # enforce (~1500 call sites). Not grandfathered - the check is off,
          # not silently ignoring findings.
          {Credo.Check.Design.AliasUsage, false},

          ## Readability Checks - things that make code easier to read
          # Disabled: large mechanical readability sweeps (alias ordering,
          # number underscores, line length, moduledocs) are deferred to
          # dedicated follow-up PRs per the plan's Scope Boundaries. Off, not
          # grandfathered; re-enable each after its sweep lands.
          {Credo.Check.Readability.AliasOrder, false},
          {Credo.Check.Readability.FunctionNames, []},
          {Credo.Check.Readability.LargeNumbers, false},
          {Credo.Check.Readability.MaxLineLength, false},
          {Credo.Check.Readability.ModuleAttributeNames, []},
          {Credo.Check.Readability.ModuleDoc, false},
          {Credo.Check.Readability.ModuleNames, []},
          {Credo.Check.Readability.ParenthesesInCondition, []},
          {Credo.Check.Readability.ParenthesesOnZeroArityDefs, []},
          {Credo.Check.Readability.PipeIntoAnonymousFunctions, []},
          # Disabled: renaming ~34 predicate functions touches every call site
          # (risky churn for a naming style); team does not enforce it.
          {Credo.Check.Readability.PredicateFunctionNames, false},
          # Disabled: implicit-try is a subjective style the team does not enforce.
          {Credo.Check.Readability.PreferImplicitTry, false},
          {Credo.Check.Readability.RedundantBlankLines, []},
          {Credo.Check.Readability.Semicolons, []},
          {Credo.Check.Readability.SpaceAfterCommas, []},
          {Credo.Check.Readability.StringSigils, []},
          {Credo.Check.Readability.TrailingBlankLine, []},
          {Credo.Check.Readability.TrailingWhiteSpace, []},
          {Credo.Check.Readability.UnnecessaryAliasExpansion, []},
          {Credo.Check.Readability.VariableNames, []},
          # Disabled: with/single-clause -> case is a subjective heuristic the
          # team does not enforce (~39 sites).
          {Credo.Check.Readability.WithSingleClause, false},

          ## Refactoring Opportunities
          # Disabled: the only apply/3 sites are intentional runtime behaviour
          # dispatch in library_item.ex, where the direct-call rewrite this
          # check requests trips the set-theoretic type checker (impl may be
          # nil). The type checker is the authoritative gate here.
          {Credo.Check.Refactor.Apply, false},
          {Credo.Check.Refactor.CondStatements, []},
          # Disabled here: judged against the merge base instead, so the ~550
          # existing findings never need a list. See .credo.ratchet.exs.
          {Credo.Check.Refactor.CyclomaticComplexity, false},
          {Credo.Check.Refactor.FilterCount, []},
          {Credo.Check.Refactor.FilterFilter, []},
          # Enabled and gating: the codebase currently passes both at zero.
          {Credo.Check.Refactor.FunctionArity, []},
          {Credo.Check.Refactor.LongQuoteBlocks, []},
          {Credo.Check.Refactor.MapJoin, []},
          {Credo.Check.Refactor.MatchInCondition, []},
          {Credo.Check.Refactor.NegatedConditionsInUnless, []},
          {Credo.Check.Refactor.NegatedConditionsWithElse, []},
          # Disabled here: judged against the merge base instead. See
          # .credo.ratchet.exs.
          {Credo.Check.Refactor.Nesting, false},
          {Credo.Check.Refactor.RedundantWithClauseResult, []},
          {Credo.Check.Refactor.RejectReject, []},
          {Credo.Check.Refactor.UnlessWithElse, []},
          {Credo.Check.Refactor.WithClauses, []},

          ## Warnings - potential problems
          {Credo.Check.Warning.ApplicationConfigInModuleAttribute, []},
          {Credo.Check.Warning.BoolOperationOnSameValues, []},
          {Credo.Check.Warning.Dbg, []},
          {Credo.Check.Warning.ExpensiveEmptyEnumCheck, []},
          {Credo.Check.Warning.IExPry, []},
          {Credo.Check.Warning.IoInspect, []},
          # Disabled: requires every Logger metadata key to be declared in
          # config; the app uses ~191 ad-hoc keys. Reconciling them is a
          # separate config sweep, not a correctness gate.
          {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, false},
          {Credo.Check.Warning.OperationOnSameValues, []},
          {Credo.Check.Warning.OperationWithConstantResult, []},
          {Credo.Check.Warning.RaiseInsideRescue, []},
          {Credo.Check.Warning.SpecWithStruct, []},
          {Credo.Check.Warning.UnsafeExec, []},
          {Credo.Check.Warning.UnusedEnumOperation, []},
          {Credo.Check.Warning.UnusedFileOperation, []},
          {Credo.Check.Warning.UnusedKeywordOperation, []},
          {Credo.Check.Warning.UnusedListOperation, []},
          {Credo.Check.Warning.UnusedPathOperation, []},
          {Credo.Check.Warning.UnusedRegexOperation, []},
          {Credo.Check.Warning.UnusedStringOperation, []},
          {Credo.Check.Warning.UnusedTupleOperation, []},
          {Credo.Check.Warning.WrongTestFileExtension, []},

          ## Type Safety - catch unsafe map/struct access.
          ## StructBracketAccess was retired here: a syntax-level check cannot
          ## tell a struct (where x[:key] raises) from a map (where it is
          ## correct), so it was majority false-positive at 308 sites. The
          ## compiler's set-theoretic type checker carries types and flags
          ## provable struct-field misuse precisely; it is enforced via
          ## `mix compile --warnings-as-errors`.
          {Credo.Check.Warning.MapGetUnsafePass, []},

          ## Type Safety - @spec enforcement
          # Disabled: mandatory @spec on every public function is a policy the
          # team has never adopted (~1788 functions lack one). The set-theoretic
          # type checker (mix compile --warnings-as-errors) provides type safety
          # without requiring hand-written specs. Re-enable if the team commits
          # to a specs sweep.
          {Credo.Check.Readability.Specs, false}
        ],
        disabled: [
          # Controversial and experimental checks (opt-in, replace `false` with `[]`)
          {Credo.Check.Design.TagTODO, []},
          {Credo.Check.Design.TagFIXME, []},
          {Credo.Check.Readability.AliasAs, []},
          {Credo.Check.Readability.BlockPipe, []},
          {Credo.Check.Readability.ImplTrue, []},
          {Credo.Check.Readability.MultiAlias, []},
          {Credo.Check.Readability.NestedFunctionCalls, []},
          {Credo.Check.Readability.SeparateAliasRequire, []},
          {Credo.Check.Readability.SingleFunctionToBlockPipe, []},
          {Credo.Check.Readability.SinglePipe, []},
          {Credo.Check.Readability.StrictModuleLayout, []},
          {Credo.Check.Readability.WithCustomTaggedTuple, []},
          {Credo.Check.Refactor.ABCSize, []},
          {Credo.Check.Refactor.AppendSingleItem, []},
          {Credo.Check.Refactor.DoubleBooleanNegation, []},
          {Credo.Check.Refactor.IoPuts, []},
          {Credo.Check.Refactor.MapMap, []},
          {Credo.Check.Refactor.ModuleDependencies, []},
          {Credo.Check.Refactor.NegatedIsNil, []},
          {Credo.Check.Refactor.PipeChainStart, []},
          {Credo.Check.Refactor.VariableRebinding, []},
          {Credo.Check.Warning.LazyLogging, []},
          {Credo.Check.Warning.LeakyEnvironment, []}
          # MapGetUnsafePass moved to enabled checks for type safety
        ]
      }
    }
  ]
}
