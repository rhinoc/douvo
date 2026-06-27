# Local LLM Prompt Lab

Edit `prompt-lab.sample.json`, `system-prompt.txt`, and `user-message.txt`, then run:

```bash
swift run Douvo --prompt-lab docs/local-llm-eval/prompt-lab.sample.json
```

The runner writes a JSON report under `~/Library/Logs/Douvo/PromptLab/`.

Useful config fields:

- `model`: a built-in model raw value such as `light`, `qwen35EightBit08B`, `qwen35EightBit2B`, or `quality`, or a local MLX model folder path.
- `runs`: repeat count per input.
- `punctuationStyle`: `complete`, `omitFinal`, or `spaces`.
- `removeFillerWords`: `true` to enable the `{{#if remove_filler_words}}` template branch.
- `softenEmotionalLanguage`: `true` to enable the `{{#if soften_emotional_language}}` template branch.
- `outputStyle`: `original`, `natural`, or `concise`. `original` leaves `{{#if output_style_instruction}}` empty.
- `outputStyleStrength`: `light`, `medium`, or `strong`; only affects non-`original` output styles.
- `reasoningMode`: `disabled` for app-equivalent ASR correction, or `enabled` for thinking-mode diagnostics.
- `maxTokens`: optional generation token budget override for diagnostics. Use `0` to leave MLX `maxTokens` unset.
- `systemPrompt` or `systemPromptFile`.
- `userPrompt` or `userPromptFile`.
- `vocabulary` or `vocabularyFile`.
- `inputs`: test cases with `id`, `text`, optional `expected`, and optional rule checks:
  - `mustContain`: string or list of strings that must appear in final app output.
  - `mustNotContain`: string or list of strings that must not appear in final app output.
  - `shouldChange`: `true` when output should differ from input, `false` when it should stay unchanged.
  - `allowFallback`: `false` when a fallback/rejected model output should fail evaluation.

Reports include `evaluation` for each attempt plus `evaluation_summary` for each case and model. Rule checks evaluate `app_output`, not raw model text, so they measure product behavior after cleanup and fallback.
