---
id: task-167.2
title: 'Phase 2: Implement PTN-style sequential extraction'
status: To Do
assignee: []
created_date: '2025-11-11 16:45'
labels:
  - enhancement
  - file-parsing
  - architecture
dependencies: []
parent_task_id: task-167
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Refactor FileParser to use sequential pattern extraction where each matched pattern is removed from the filename, leaving only the title.

## Algorithm

```elixir
@patterns [
  %{name: :year, regex: ~r/[\(\[]?(19\d{2}|20\d{2})[\)\]]?/},
  %{name: :resolution, regex: @resolution_pattern},
  %{name: :source, regex: @source_pattern},
  %{name: :codec, regex: @codec_pattern},
  %{name: :audio, regex: @audio_pattern},
  # ... more patterns
]

def parse(filename) do
  {metadata, remaining} = Enum.reduce(@patterns, {%{}, filename}, fn pattern, {meta, text} ->
    extract_and_remove(pattern, meta, text)
  end)
  
  Map.put(metadata, :title, clean_title(remaining))
end
```

## Tasks

1. Create pattern-based extraction system
2. Implement sequential reduction over patterns
3. Update title extraction to use remaining text
4. Create FileParser.V2 module (non-breaking)
5. Add comprehensive test suite
6. Benchmark against V1 for accuracy

## Expected Outcome

- Clean title extraction (what remains after removing all patterns)
- Better handling of edge cases
- More maintainable codebase

## Effort: 1-2 days
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 FileParser.V2 module created and functional
- [ ] #2 Sequential extraction correctly removes matched patterns from filename
- [ ] #3 Title is extracted from remaining text after pattern removal
- [ ] #4 Passes comprehensive test suite (100+ test cases)
- [ ] #5 Accuracy matches or exceeds V1 parser
- [ ] #6 Performance benchmarked (should be comparable to V1)
<!-- AC:END -->
