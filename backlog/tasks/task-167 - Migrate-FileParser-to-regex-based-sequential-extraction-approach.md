---
id: task-167
title: Migrate FileParser to regex-based sequential extraction approach
status: To Do
assignee: []
created_date: '2025-11-11 16:44'
labels:
  - enhancement
  - architecture
  - file-parsing
  - technical-debt
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Problem Statement

The current FileParser uses a list-based pattern matching approach that is brittle and requires constant maintenance. Every new codec variant (DDP5.1, EAC3, etc.) requires manual addition to lists, and edge cases multiply over time.

## Solution

Adopt a regex-based sequential extraction approach similar to industry-standard parsers (PTN, GuessIt) that are battle-tested on millions of filenames.

## Benefits

- **Robust**: Patterns handle variations automatically (DD5.1, DD51, DDP5.1 all matched by one pattern)
- **Maintainable**: Add pattern once instead of every variant
- **Scalable**: Gracefully handles edge cases
- **Industry Standard**: Aligns with proven approaches

## Approach

Three-phase migration:

1. **Phase 1** (2-4 hours): Replace static lists with flexible regex patterns
2. **Phase 2** (1-2 days): Implement PTN-style sequential extraction  
3. **Phase 3** (1 week): Add standardization layer and comprehensive testing

## References

- Analysis document: `docs/file_parser_analysis.md`
- PTN: https://github.com/divijbindlish/parse-torrent-name
- GuessIt: https://github.com/guessit-io/guessit

## Success Metrics

- Parse 1000+ real-world filenames with 95%+ accuracy
- Handle new codec variants without code changes
- Reduce maintenance burden (no more list updates)
- Pass comprehensive test suite
<!-- SECTION:DESCRIPTION:END -->
