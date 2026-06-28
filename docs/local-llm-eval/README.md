# Local LLM Prompt Lab

Edit `prompt-lab.sample.json`, `system-prompt.txt`, and `user-message.txt`, then run:

```bash
swift run Douvo --prompt-lab docs/local-llm-eval/prompt-lab.sample.json
```

Structured style check:

```bash
swift run Douvo --prompt-lab docs/local-llm-eval/prompt-lab.structured.json
```

The runner writes a JSON report under `~/Library/Logs/Douvo/PromptLab/`.

Useful config fields:

- `model`: a built-in model raw value such as `light`, `qwen35EightBit08B`, `qwen35EightBit2B`, or `quality`, or a local MLX model folder path.
- `runs`: repeat count per input.
- `punctuationStyle`: `complete`, `omitFinal`, `spaces`, or `questionMarksOnly`.
- `removeFillerWords`: `true` to enable the `{{#if remove_filler_words}}` template branch.
- `softenEmotionalLanguage`: `true` to enable the `{{#if soften_emotional_language}}` template branch.
- `outputStyle`: `original`, `natural`, `concise`, `structured`, or `custom`. `original` leaves `{{#if output_style_instruction}}` empty.
- `outputStyleStrength`: `light`, `medium`, or `strong`; affects `natural`, `concise`, and `structured`.
- `customOutputStyleInstruction`: instruction text used when `outputStyle` is `custom`.
- `environmentContext`: optional fixed text for `{{environment_context}}`. Prompt Lab does not collect live app context.
- `userIdentity` or `userIdentityFile`: optional fixed text for `{{user_identity}}`.
- `selectedText`: optional fixed text for `{{selected_text}}` to test Selection Editing prompt branches.
- `reasoningMode`: `disabled` for app-equivalent ASR correction, or `enabled` for thinking-mode diagnostics.
- `maxTokens`: optional generation token budget override for diagnostics. Use `0` to leave MLX `maxTokens` unset.
- `systemPrompt` or `systemPromptFile`.
- `incrementalSystemPrompt` or `incrementalSystemPromptFile`: optional fragment appended after the effective system prompt.
- `userPrompt` or `userPromptFile`.
- `vocabulary` or `vocabularyFile`.
- `inputs`: test cases with `id`, `text`, optional `expected`, and optional rule checks:
  - `mustContain`: string or list of strings that must appear in final app output.
  - `mustNotContain`: string or list of strings that must not appear in final app output.
  - `shouldChange`: `true` when output should differ from input, `false` when it should stay unchanged.
  - `allowFallback`: `false` when a fallback/rejected model output should fail evaluation.

Reports include `evaluation` for each attempt plus `evaluation_summary` for each case and model. Rule checks evaluate `app_output`, not raw model text, so they measure product behavior after cleanup and fallback.

Advanced prompt syntax and variables are documented in [Advanced Prompts](../advanced-prompts.md).
