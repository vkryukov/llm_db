# ETL Pipeline Refactor: 7-Stage to 5-Stage

## Summary

Streamline the LLMModels.Engine ETL pipeline from 7 stages to 5 stages by combining Filter, Enrich, and Index into a single "Finalize" stage. This reduces redundant passes over data and simplifies the mental model while maintaining clear architectural boundaries and full testability.

## Current State (7-Stage Pipeline)

```
1. Ingest     → Read sources (packaged, config, behaviour) and filters
2. Normalize  → Convert provider IDs, models, modalities to canonical forms
3. Validate   → Run Zoi validation, drop invalid entries, log counts
4. Merge      → Precedence-aware deep merge across sources
5. Enrich     → Derive family, ensure provider_model_id, apply defaults
6. Filter     → Apply allow/deny patterns to models
7. Index      → Build lookup indexes (providers_by_id, models_by_key, aliases_by_key)
8. (Ensure)   → Verify catalog has content
```

## Proposed State (5-Stage Pipeline)

```
1. Ingest     → Read sources (packaged, config, behaviour) and filters
2. Normalize  → Convert provider IDs, models, modalities to canonical forms
3. Validate   → Run Zoi validation, drop invalid entries, log counts
4. Merge      → Precedence-aware deep merge across sources
5. Finalize   → Filter + Enrich + Index (combined)
   - Apply allow/deny patterns to models
   - Derive family, ensure provider_model_id
   - Build lookup indexes
   - Build complete snapshot structure
   - Return indexed snapshot
6. (Ensure)   → Verify catalog has content
```

## Rationale

### Why Combine Filter + Enrich + Index?

1. **Logical cohesion**: These three stages are sequential transformations that don't have reusable boundaries outside the pipeline
   - Filter produces the final model set
   - Enrich adds derived fields to that set
   - Index builds lookups from the enriched set

2. **Single pass efficiency**: Currently we iterate over models three times; combining saves two full passes

3. **Clearer mental model**: "Finalize" clearly communicates "prepare the final snapshot"

4. **No loss of testability**: All existing functions (`filter/1`, `enrich/1`, `build_indexes/2`) remain as private helpers and can be tested independently

### Why Keep Normalize and Validate Separate?

1. **Clear architectural boundary**: Normalization transforms data shape; validation enforces correctness
2. **Different concerns**: Normalization is about canonicalization; validation is about schema compliance
3. **Debugging clarity**: Separate stages make it easier to see where data transformation vs rejection happens
4. **Logging semantics**: Validation logs dropped records; combining would muddle telemetry

## Implementation Plan

### Phase 1: Create Finalize Stage

#### 1.1 Add `finalize/1` Private Function

Location: `lib/llm_models/engine.ex`

```elixir
# Stage 5: Finalize (Filter → Enrich → Index)
defp finalize(merged) do
  # Step 1: Filter
  compiled_filters = Config.compile_filters(merged.filters.allow, merged.filters.deny)
  filtered_models = apply_filters(merged.models, compiled_filters)

  # Step 2: Enrich
  enriched_models = Enrich.enrich_models(filtered_models)

  # Step 3: Index
  indexes = build_indexes(merged.providers, enriched_models)

  # Step 4: Build snapshot
  snapshot = %{
    providers_by_id: indexes.providers_by_id,
    models_by_key: indexes.models_by_key,
    aliases_by_key: indexes.aliases_by_key,
    providers: merged.providers,
    models: indexes.models_by_provider,
    filters: compiled_filters,
    prefer: merged.prefer,
    meta: %{
      epoch: nil,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  }

  {:ok, snapshot}
end
```

#### 1.2 Update `run/1` Function

**Before:**
```elixir
def run(opts \\ []) do
  with {:ok, sources} <- ingest(opts),
       {:ok, normalized} <- normalize(sources),
       {:ok, validated} <- validate(normalized),
       {:ok, merged} <- merge(validated),
       {:ok, enriched} <- enrich(merged),
       {:ok, filtered} <- filter(enriched),
       {:ok, snapshot} <- build_snapshot(filtered),
       :ok <- ensure_viable(snapshot) do
    {:ok, snapshot}
  end
end
```

**After:**
```elixir
def run(opts \\ []) do
  with {:ok, sources} <- ingest(opts),
       {:ok, normalized} <- normalize(sources),
       {:ok, validated} <- validate(normalized),
       {:ok, merged} <- merge(validated),
       {:ok, snapshot} <- finalize(merged),
       :ok <- ensure_viable(snapshot) do
    {:ok, snapshot}
  end
end
```

#### 1.3 Keep Existing Helper Functions

**Do NOT remove:**
- `filter/1` - Keep as private helper (may be useful for testing/debugging)
- `enrich/1` - Keep as private helper
- `build_snapshot/1` - Keep as private helper
- `build_indexes/2` - Keep as public function (already used in tests)
- `apply_filters/2` - Keep as public function (already used in tests/API)
- `build_aliases_index/1` - Keep as public function

These functions remain testable independently but are called from within `finalize/1`.

### Phase 2: Update Documentation

#### 2.1 Update Module Documentation

File: `lib/llm_models/engine.ex`

Update `@moduledoc` to reflect 5-stage pipeline:

```elixir
@moduledoc """
Orchestrates the complete ETL pipeline for LLM model catalog generation.

The engine coordinates data ingestion, normalization, validation, merging,
and finalization to produce a comprehensive model snapshot.
"""
```

#### 2.2 Update `run/1` Documentation

Update the "Pipeline Stages" section in `run/1` docs:

```elixir
## Pipeline Stages

1. **Ingest** - Collect data from sources in precedence order
2. **Normalize** - Apply normalization to providers and models
3. **Validate** - Validate schemas and log dropped records
4. **Merge** - Combine sources with precedence rules
5. **Finalize** - Filter, enrich, and index the final catalog
6. **Ensure viable** - Verify catalog has content
```

#### 2.3 Update Stage Comments

Update inline stage comments:

```elixir
# Stage 1: Ingest
# Stage 2: Normalize
# Stage 3: Validate
# Stage 4: Merge
# Stage 5: Finalize (Filter → Enrich → Index)
# Stage 6: Ensure viable
```

### Phase 3: Update OVERVIEW.md

File: `OVERVIEW.md`

Update the "ETL Pipeline Architecture" section:

**Before:**
```markdown
### Stages (`LLMModels.Engine.run/1`)

#### 1. Ingest
...
#### 2. Normalize
...
#### 3. Validate
...
#### 4. Merge
...
#### 5. Enrich
...
#### 6. Filter
...
#### 7. Index (+ Publish by caller)
...
```

**After:**
```markdown
### Stages (`LLMModels.Engine.run/1`)

#### 1. Ingest
Read sources (packaged snapshot, config overrides, behaviour overrides) and runtime filters/preferences from `Config`.

#### 2. Normalize
- Normalize provider IDs, models, and modalities (convert known modality strings to atoms)
- Preserve excludes and filters

#### 3. Validate
- Validate all providers/models against Zoi schemas (`LLMModels.Validate.*`)
- Invalid entries are dropped; counts are logged

#### 4. Merge
- Precedence-aware deep merge of providers/models:
  - **Packaged < Config overrides < Behaviour overrides**
- Excludes are merged (later wins) and applied to models by provider via exact or glob patterns

#### 5. Finalize
Combines filtering, enrichment, and indexing into a single stage:

- **Filter**: Compile allow/deny patterns to Regex once (globs supported); deny wins over allow
- **Enrich**: Derive model family from ID, ensure `provider_model_id` is set, apply capability defaults
- **Index**: Build lookup indexes for O(1) access
- **Build snapshot**: Assemble final snapshot structure with metadata

Engine returns the snapshot; the caller (`LLMModels.load/1`) publishes it atomically to `:persistent_term`.
```

### Phase 4: Testing Strategy

#### 4.1 Verify Existing Tests Pass

Run the full test suite:

```bash
mix test
```

All existing tests should pass without modification because:
- Public functions (`build_indexes/2`, `apply_filters/2`, `build_aliases_index/1`) remain unchanged
- Private helper functions remain available for internal testing if needed
- Pipeline output (snapshot structure) remains identical

#### 4.2 Add Finalize-Specific Test (Optional)

If desired, add a test specifically for the `finalize/1` stage to verify the combined behavior:

```elixir
describe "finalize/1" do
  test "applies filters, enrichment, and builds indexes in single stage" do
    merged = %{
      providers: [%{id: :openai, name: "OpenAI"}],
      models: [
        %{id: "gpt-4", provider: :openai, name: "GPT-4"},
        %{id: "gpt-3.5-turbo", provider: :openai, name: "GPT-3.5"}
      ],
      filters: %{allow: :all, deny: %{openai: ["gpt-3.5-turbo"]}},
      prefer: [:openai]
    }

    {:ok, snapshot} = Engine.finalize(merged)

    # Verify filtering happened (gpt-3.5-turbo should be excluded)
    assert map_size(snapshot.models_by_key) == 1
    assert Map.has_key?(snapshot.models_by_key, {:openai, "gpt-4"})
    refute Map.has_key?(snapshot.models_by_key, {:openai, "gpt-3.5-turbo"})

    # Verify enrichment happened (family derived)
    model = snapshot.models_by_key[{:openai, "gpt-4"}]
    assert model.family == "gpt"

    # Verify indexes built
    assert snapshot.providers_by_id[:openai]
    assert snapshot.models[:openai]
  end
end
```

## Benefits

### Performance

- **Fewer passes over data**: Reduce from 3 iterations (filter → enrich → index) to 1
- **Memory efficiency**: Don't materialize intermediate filtered/enriched structures
- **Faster pipeline execution**: Especially noticeable with large catalogs

### Maintainability

- **Clearer mental model**: 5 stages vs 7 is easier to understand
- **Logical grouping**: Final data preparation steps are clearly grouped
- **Simpler pipeline flow**: Less visual noise in `run/1` with statement

### No Loss of Functionality

- **All helper functions preserved**: Can still test/debug individual pieces
- **Public API unchanged**: `build_indexes/2` and `apply_filters/2` remain public
- **Same output**: Snapshot structure identical to before
- **Same semantics**: Precedence, filtering, enrichment logic unchanged

## Risks and Mitigations

### Risk: Breaking Existing Tests

**Likelihood**: Low

**Mitigation**: 
- Keep all existing helper functions intact
- Public functions (`build_indexes/2`, `apply_filters/2`, `build_aliases_index/1`) unchanged
- Run full test suite to verify

### Risk: Harder to Debug Individual Stages

**Likelihood**: Low

**Mitigation**:
- Keep `filter/1`, `enrich/1`, `build_snapshot/1` as private helpers
- Can still call individually in IEx for debugging
- Can add breakpoints within `finalize/1` to inspect state between steps

### Risk: Merge Conflicts During Implementation

**Likelihood**: Low (single file change)

**Mitigation**:
- Make changes in single atomic commit
- Run tests immediately after

## Rollback Plan

If issues arise, rollback is straightforward:

1. Revert `finalize/1` addition
2. Restore original `run/1` with 7-stage flow
3. Restore original stage functions (`enrich/1`, `filter/1`, `build_snapshot/1`)

Since all helper functions are preserved, this is a low-risk refactor.

## Success Criteria

- [ ] All existing tests pass (`mix test`)
- [ ] Pipeline produces identical snapshot output
- [ ] `run/1` reflects 5-stage flow
- [ ] Documentation updated (module docs, function docs, OVERVIEW.md)
- [ ] Stage comments updated
- [ ] No performance regression (verify with `:timer.tc` if needed)

## Effort Estimate

- **Code changes**: S (30-60 minutes)
  - Add `finalize/1` function
  - Update `run/1`
  - Update stage comments
- **Documentation updates**: S (30 minutes)
  - Update module docs
  - Update OVERVIEW.md
- **Testing**: S (15 minutes)
  - Run test suite
  - Verify output

**Total**: M (1-2 hours)

## Optional Future Enhancements

### Filter Before Merge (Performance Optimization)

Currently, we merge all models from all sources, then filter. For very large datasets, we could filter earlier to reduce merge work:

```
Merge → Filter → Enrich+Index
```

However, this complicates validation logging (we'd be reporting dropped counts on a filtered set) and requires applying filters per-source. Only consider if profiling shows merge is a bottleneck.

### Single-Pass Normalize+Validate

If memory allocation becomes a concern, we could inline validation into normalization to avoid materializing the full normalized structure. This is a larger refactor and should only be done if profiling shows benefit.

---

**Recommendation**: Proceed with 5-stage refactor. Low risk, clear benefits, no API/behavior changes.
