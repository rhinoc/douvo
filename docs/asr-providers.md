# ASR Providers

Douvo supports three ASR recognition paths: Doubao `Web`, Doubao `Android`, and Youdao `Bage Shuo`. Choose one or more paths in **Settings... -> Account -> Recognition**. Multiple paths run in parallel and require AI post-processing to merge their results. The default provider is `Web`.

All paths are based on observed client behavior, not an official public API. Any path may break if the service changes authentication, risk controls, WebSocket protocols, audio formats, or response payloads.

## Bage Shuo Provider

The Bage Shuo provider follows the Youdao desktop client's realtime dictation path. It is a separate route from the Doubao providers and does not use Doubao cookies or Android credentials.

### Authentication and Local Credentials

1. Douvo checks its own snapshot at `~/Library/Application Support/Douvo/bageshuo_asr_params.json` and the installed Bage Shuo app's account store at `~/Library/Application Support/com.bageshuo/bageshuo-store.json` plus native cookie store at `~/Library/HTTPStorages/com.bageshuo.binarycookies`.
2. When Douvo has no usable login, it imports the complete native cookie set, the logged-in Youdao user, and the installed app's `deviceId`. Douvo records that the snapshot came from the installed app and can update it when the installed app's credentials change.
3. Cookies obtained from the official page are saved locally as Douvo's active credentials. They take precedence over later changes in the installed app's cookie store, so a successful Douvo login is not overwritten by the native-cookie importer.
4. Immediately before requesting a realtime ticket, Douvo attempts the same session rehydration used by the installed client only when the active credentials came from the installed app: `POST https://dict.youdao.com/login/acc/poll` with the stored `accountSessionToken`. If no usable credentials are available, Douvo opens the official Bage Shuo login page in an embedded `WKWebView`. Account/password, phone/SMS verification, and any other methods are handled by the page as Youdao currently exposes them; Douvo does not implement or store a separate login form.
5. The active cookies are sent as both `X-Typeless-User` and `Cookie` headers when requesting a realtime ticket.

### Bage Shuo Vocabulary

The installed Bage Shuo client exposes a signed, account-bound hot-word list at
`https://dict-typeless.youdao.com/api/v1/hot-words`. Douvo reads that list with the
same ticket-signing context and Youdao session headers, follows the client's
zero-based pagination (`limit=100`), and stores a local snapshot separately from
the manually configured Douvo vocabulary. The merged vocabulary is used by local
AI post-processing and, when enabled, the Doubao Android personal lexicon.

When Bage Shuo is selected, Douvo automatically performs an additive merge after
launch, login, provider selection, and local vocabulary changes: terms already in
Bage Shuo are imported into Douvo, and manual Douvo terms missing from Bage Shuo
are created there. It does not delete remote terms when a local term is removed.
A failed sync keeps the last successful local snapshot.

The local file is:

```text
~/Library/Application Support/Douvo/bageshuo_asr_params.json
```

After a successful import from the installed app, Douvo keeps its own snapshot at the path above. The installed app's WebKit cookie database is not directly shared between app bundles, so Douvo reads the native cookie file and uses the account session rehydration endpoint when the installed session can still be refreshed.

### Ticket and WebSocket Protocol

The ticket request is a signed `POST` to:

```text
https://dict-typeless.youdao.com/api/v1/realtime/tickets
```

Its JSON body is:

```json
{"protocolVersion":1,"capabilities":{"generationStreaming":true}}
```

The query contains the observed client identity fields plus `mysticTime`, `sign`, and `pointParam`. The signature is an MD5 of the sorted `key=value` pairs followed by the bundled client signing key. The response contains `ticketInfo.websocketUrl`; Douvo validates its ticket, protocol version, and audio policy before connecting.

After `connection.ready`, Douvo sends an `utterance.start` JSON frame for the `POLISH` operation. It then sends raw binary PCM frames and ends with `utterance.end`, including the number of audio bytes and the corresponding duration. The recognized text is streamed through `transcript.partial`; `generation.completed.resultText` is used as the final result.

### Audio and Results

```text
AVAudioEngine -> 16 kHz mono PCM_S16LE -> WebSocket binary frame
```

The current capture path emits 200 ms frames (6,400 bytes) and buffers audio until `utterance.ready`. The final processed text arrives from `generation.completed`, while partial text is shown through the same floating overlay and insertion pipeline as the Doubao providers.

## Web Provider

The Web provider uses Doubao's web product login and ASR flow.

### Authentication and Local Credentials

1. Douvo opens Doubao in an embedded `WKWebView`, and the user logs in manually.
2. After login, the app reads `doubao.com` cookies.
3. The app reads browser identifiers from local storage:
   - `web_id` from `samantha_web_web_id` is used as `device_id`.
   - `web_id` from `__tea_cache_tokens_497858` is used as `web_id` and `tea_uuid`.
4. Cookies, `device_id`, and `web_id` are saved locally:

```text
~/Library/Application Support/Douvo/asr_params.json
```

### WebSocket and Protocol

The Web provider connects to:

```text
wss://ws-samantha.doubao.com/samantha/audio/asr
```

Key query parameters:

| Parameter | Value or source |
| --- | --- |
| `aid` / `real_aid` | `497858` |
| `device_platform` | `web` |
| `device_id` | `web_id` from `samantha_web_web_id` |
| `web_id` / `tea_uuid` | `web_id` from `__tea_cache_tokens_497858` |
| `format` | `pcm` |
| `language` | `zh` |

The request also sends the saved login cookies, `Origin: https://www.doubao.com`, and the same browser `User-Agent` used by the login WebView.

### Audio and Results

The audio path is:

```text
AVAudioEngine -> 16 kHz mono PCM -> WebSocket binary frame
```

The Web provider sends 16 kHz mono PCM chunks. Each current chunk contains 2048 samples, about 128 ms of audio. When recording stops, Douvo sends a JSON finish frame:

```json
{"event":"finish"}
```

Recognition results are read from JSON server messages. Interim and final text mainly come from `result.Text` in `event=result` messages, then flow into the floating overlay and final insertion pipeline.

## Android Provider

The Android provider follows the Doubao IME Android ASR protocol. It does not require the embedded WebView login, but it does register a locally generated device identity and stores credentials returned by Doubao.

### Device Identity and Local Credentials

On first use, Douvo generates:

| Field | Meaning |
| --- | --- |
| `cdid` | UUID string |
| `openudid` | Hex string from 8 random bytes |
| `clientudid` | UUID string |

It then calls the device registration endpoint:

```text
https://log.snssdk.com/service/2/device_register/
```

Registration uses Doubao IME Android client metadata, including:

| Parameter | Value |
| --- | --- |
| `aid` | `401734` |
| `app_name` | `oime` |
| `package` | `com.bytedance.android.doubaoime` |
| `device_platform` | `android` |
| `device_type` / `device_model` | `Pixel 7 Pro` |
| `os_version` | `16` |

If registration succeeds, the server returns `deviceId` and `installId`. Douvo then requests the settings endpoint to fetch the ASR token:

```text
https://is.snssdk.com/service/settings/v3/
```

The app key is read from `data.settings.asr_config.app_key`. It is distinct from
the device authentication JSON attached to the WebSocket URL. The complete
Android credential set is saved locally:

```text
~/Library/Application Support/Douvo/android_asr_credentials.json
```

Clicking **Reset Android Login** in Settings deletes this file. The next Android-provider run generates a new local identity and registers again, so Doubao will see it as a new IME-style device.

### WebSocket and Protocol

The Android provider connects to:

```text
wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws?aid=401734&device_id=<device-id>
```

Key request headers:

| Header | Value |
| --- | --- |
| `User-Agent` | Doubao IME Android client user agent |
| `proto-version` | `v2` |
| `x-custom-keepalive` | `true` |

Messages are Protobuf-encoded. The current implementation sends:

| Method | Purpose |
| --- | --- |
| `StartTask` | Creates an ASR task with the settings `app_key` |
| `StartSession` | Sends session configuration and audio parameters |
| `TaskRequest` | Sends audio frames |
| `FinishSession` | Ends the session |

The important `StartSession` config is:

```json
{
  "audio_info": {
    "channel": 1,
    "format": "speech_opus",
    "sample_rate": 16000
  },
  "enable_punctuation": true,
  "extra": {
    "did": "<deviceId>",
    "disable_user_words": false,
    "enable_asr_twopass": true,
    "enable_asr_threepass": true,
    "input_mode": "tool"
  }
}
```

### Personal Lexicon

The Android provider can upload the vocabulary configured in Douvo to Doubao's
device-scoped personal lexicon. This is separate from `extra.context`: context is
a soft conversation-history hint, while the personal lexicon is enabled by
`disable_user_words=false` in `StartSession`.

When the feature is enabled and the local vocabulary changes, Douvo performs:

1. `POST https://ime.oceancloudapi.com/api/v1/user/get_config` to obtain a short-lived context token.
2. A P-256 Wave handshake with `https://keyhub.zijieapi.com/handshake`.
3. A ChaCha20-encrypted upload to `https://speech.bytedance.com/api/v3/context/ime/user_words`.

Only a device id and per-word SHA-256 digests are cached locally after a successful
upload; the word list is not duplicated into that cache. Only missing terms are
uploaded on later runs. The protocol has no verified per-word deletion operation, so a
locally removed term may remain on Doubao's service. Turning Personal Lexicon off
sends `disable_user_words=true`, preventing those remote terms from being used by
new Android recognition sessions.

### Audio and Results

The audio path is:

```text
AVAudioEngine -> 16 kHz mono PCM -> AudioToolbox Opus encoder -> Protobuf TaskRequest
```

The Android provider encodes 16 kHz mono audio as Opus. Each audio frame is 20 ms, or 320 samples at 16 kHz. Frames are sent with `frame_state`:

| `frame_state` | Meaning |
| --- | --- |
| `1` | First frame |
| `3` | Middle audio frame |
| `9` | Last frame |

When recording stops, Douvo sends a final audio frame and then `FinishSession`.

Server responses are also Protobuf-encoded. Douvo parses `message_type` and `result_json`, then extracts structured recognition results from fields such as `results[].text`, `is_interim`, `is_vad_finished`, and `nonstream_result`.

`results` can contain multiple text segments. Douvo parses all non-empty `results[].text` segments for one recognition update instead of taking only the last segment. The Android provider then maintains an in-session segment map keyed by provider segment identity (`index`, falling back to time range or result order). A newer interim/final update for the same segment replaces the old text instead of being appended again; distinct segment ids are ordered and joined into the current transcript.

Trace metadata records the Android segment shape (`android_result_segments`, `android_text_segments`, `android_interim_segments`, `android_final_segments`, `android_vad_finished_segments`, `android_result_keys`, `android_segment_ids`, `android_assembled_segments`, and `android_assembled_segment_ids`) so provider behavior can be diagnosed from a failed trace.

### Headless ASR Lab

Generate an audio fixture with `say`, then send it through the same conversion,
streaming, and finalization path without opening the app or using the microphone:

```bash
say -v Tingting -o /tmp/douvo-asr-lab.aiff '请创建一个 worktree，然后提交 pull request。'
swift run Douvo --asr-lab /tmp/douvo-asr-lab.aiff --providers android
```

Use `--providers web,android,bageshuo` to select one or more routes. Each route
can also be tested independently from **Settings... -> System -> Recognition**.
Bage Shuo uses the local Bage Shuo login parameters saved by Douvo. Android experiments can add
`--context 'prior conversation'`. Use `--vocabulary 'worktree,Claude Code'` to
upload and enable the personal lexicon before recognition. The command prints the
final transcript for each selected route and returns a nonzero exit status when a
selected route fails to open, finish, or produce text.

## Multi-route Recognition

When multiple routes are selected, Douvo starts every selected provider for the same recording and sends each route its required audio format. Web and Bage Shuo receive PCM; Android receives Opus Protobuf frames. The routes are independent, so one route can fail while the remaining routes continue.

Multi-route recognition requires:

- Every selected login-based route to have valid credentials.
- Android ASR credentials to be available or creatable when Android is selected.
- AI post-processing to be enabled.

During recording, the same microphone capture is converted into each required audio format:

```text
AVAudioEngine -> 16 kHz mono PCM -> Web ASR
                         |-> Bage Shuo ASR
                         \-> AudioToolbox Opus encoder -> Android ASR
```

Douvo keeps a separate transcript accumulator for every selected provider so routes do not overwrite each other's intermediate results. On completion, the correction prompt includes every non-empty provider transcript. The model is instructed to combine overlapping content, use any route to fill obvious omissions or misrecognitions, and avoid duplicate output. If only one route produces text, Douvo falls back to that transcript. If all available routes produce equivalent text, Douvo skips the merge prompt and uses the single transcript.

## Comparison

| Item | Web | Android | Bage Shuo | Multi-route |
| --- | --- | --- | --- | --- |
| Entry point | Doubao Web ASR | Doubao IME Android ASR | Youdao Bage Shuo realtime ASR | Any selected combination |
| Requires WebView login | Yes | No | Fallback only | For each selected login-based route |
| Requires AI post-processing | No | No | No | Yes |
| Local identity | Doubao cookies, `device_id`, `web_id` | `cdid`, `openudid`, `clientudid`, `deviceId`, `installId`, ASR token | Youdao cookies, signed ticket context | All selected routes |
| Local credential file | `asr_params.json` | `android_asr_credentials.json` | `bageshuo_asr_params.json` | All selected files |
| ASR host | `ws-samantha.doubao.com` | `frontier-audio-ime-ws.doubao.com` | Ticket-selected Youdao host | All selected hosts |
| Message format | JSON control frames + binary PCM audio frames | Protobuf task/session messages + Opus audio frames | JSON control frames + binary PCM audio frames | Each route's native format |
| Audio format | 16 kHz mono PCM | 16 kHz mono Opus | 16 kHz mono `PCM_S16LE` | Each route's native format |
| Common failures | Expired login, incomplete cookies, changed web fields | Device registration failure, token fetch failure, Protobuf or risk-control changes | Expired login, ticket/signature changes, returned audio-policy changes | Any route failure, correction backend unavailable |

## Network Notes

The Android provider needs these domains to be reachable:

```text
log.snssdk.com
is.snssdk.com
frontier-audio-ime-ws.doubao.com
ime.oceancloudapi.com
keyhub.zijieapi.com
speech.bytedance.com
```

`log.snssdk.com` is commonly matched by ad-blocking rules. If a router, proxy, OpenClash, or fake-ip setup redirects or blocks it, device registration can fail. In the app log, this often appears as a TLS connection failure. When this happens, check ad filters, rule sets, and DNS fake-ip policies for the domains above.

The Web provider needs normal access to Doubao Web and `ws-samantha.doubao.com`, and the locally saved cookies must still be valid.

The Bage Shuo provider needs `dict-typeless.youdao.com`, the WebSocket host returned
by its ticket response, and a valid Youdao login cookie set.

## Privacy and Risk

- Doubao Web, Doubao Android, and Bage Shuo send microphone audio to their respective service for recognition.
- Enabling Android Personal Lexicon uploads the configured vocabulary terms to Doubao and may persist them remotely after local removal.
- The Web provider stores Doubao web login parameters; Bage Shuo stores Youdao web login parameters; the Android provider stores IME-style device credentials and an ASR token.
- Do not commit or share `asr_params.json`, `bageshuo_asr_params.json`, `android_asr_credentials.json`, or credential values copied from logs.
- None of these providers is an official stable API, so they may require future maintenance when a client or service changes behavior.
