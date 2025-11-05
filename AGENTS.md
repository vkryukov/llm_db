# AGENTS.md

## Commands

- **Test all**: `mix test`
- **Test single file**: `mix test test/path/to/file_test.exs`
- **Test single test**: `mix test test/path/to/file_test.exs:12` (line number)
- **Test with coverage**: `mix test --cover`
- **Format code**: `mix format`
- **Compile**: `mix compile`
- **Update model data**: `mix llm_models.pull` (fetches from models.dev)
- **Dependencies**: `mix deps.get`

## Architecture

- **Type**: Elixir library providing fast, persistent_term-backed LLM model metadata catalog
- **Core modules**: `LlmModels` (main API), `LlmModels.Engine` (ETL pipeline), `LlmModels.Store` (persistent_term storage)
- **Data structures**: `LlmModels.Provider`, `LlmModels.Model` with Zoi validation schemas in `lib/llm_models/schema/`
- **Storage**: O(1) lock-free queries via `:persistent_term`, snapshot in `priv/llm_models/snapshot.json`
- **ETL Pipeline**: Ingest → Normalize → Validate → Merge → Enrich → Filter → Index + Publish (7 stages)

## Code Style

- **Validation**: Use `Zoi.parse/2` for all schema validation and defaulting (not NimbleOptions or typed_struct)
- **Format**: Run `mix format` before committing (configured in .formatter.exs)
- **Naming**: Snake_case for functions/vars, PascalCase for modules, atoms for provider IDs (`:openai`, `:anthropic`)
- **Error handling**: Return `{:ok, result}` or `{:error, reason}` tuples, use `:error` atom for simple failures
- **Specs**: Provider IDs are atoms, model IDs are strings, spec format is `"provider:model"`
- **Tests**: Use `async: false` for tests that modify Store, `setup` blocks to clear state with `Store.clear!()`
