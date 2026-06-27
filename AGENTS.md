# Agent and Contributor Notes

This repository is a native macOS app. Treat changes carefully because the app touches microphone input, Accessibility permissions, clipboard state, local Doubao credentials, optional local MLX models, and optional remote LLM providers.

## Default workflow

- Inspect relevant files before editing. Do not guess about prompt, model, signing, or permission behavior.
- Keep changes scoped. Do not reformat or refactor unrelated files.
- The worktree may already contain user or other-agent changes. Do not revert them unless explicitly asked.
- Prefer `rg` for search.
- Use `swift test` for code changes when feasible.
- For prompt or correction behavior changes, run a focused Prompt Lab config when feasible:

```bash
swift run Douvo --prompt-lab docs/local-llm-eval/prompt-lab.sample.json
```

## Do not run the user app process casually

- Do not start, stop, kill, or restart a user's running Douvo app unless explicitly asked.
- `swift test` and `swift run Douvo --prompt-lab ...` are acceptable verification commands.
- If UI/manual testing is required, say exactly what must be run and why before doing it.

## Code signing matters

Do not bypass signing with ad-hoc signatures. A locally built `.app` needs a stable code-signing identity because macOS Accessibility permissions and app identity are signature-sensitive. Ad-hoc builds can appear to work once and then fail after rebuilds or permission changes.

`scripts/build-app.sh` intentionally refuses ad-hoc signing. It requires one of:

- `CODESIGN_IDENTITY` set to a valid local signing identity.
- A local keychain identity named `Douvo Local Code Signing`.

Check available identities:

```bash
security find-identity -v -p codesigning
```

Create a local identity with Keychain Access:

1. Open **Keychain Access**.
2. Choose **Certificate Assistant -> Create a Certificate...**.
3. Name it `Douvo Local Code Signing`.
4. Set **Identity Type** to **Self Signed Root**.
5. Set **Certificate Type** to **Code Signing**.
6. Create it in the login keychain.

Then build:

```bash
./scripts/build-app.sh
open .build/release/Douvo.app
```

If you use a different certificate name:

```bash
CODESIGN_IDENTITY="Your Code Signing Identity" ./scripts/build-app.sh
```

## Local MLX build notes

- `Package.swift` includes MLX, Hugging Face, Tokenizers, and Sparkle dependencies.
- `scripts/build-app.sh` runs `scripts/build-mlx-metallib.sh` and packages the MLX Metal library into the app bundle.
- If local model inference fails, inspect the MLX runtime diagnostic in Settings before changing model code.

## Prompt and correction changes

- Keep default prompt text short.
- Put broad safety constraints once in the global output requirements, not repeated in every optional branch.
- Do not hard-code a single Prompt Lab failure case into the general prompt.
- Prefer engineering candidates, vocabulary normalization, and unit tests before strengthening prompts.
- When changing model lists, update `README.md`, `README.zh.md`, and `docs/local-llm-eval`.

## Privacy boundaries

- Never log cookies, full credential JSON, remote API keys, or secret values.
- Remote LLM API keys must stay in Keychain.
- Prompt snapshots, traces, and Prompt Lab reports may contain transcript text. Keep them local unless the user explicitly chooses to share them.
