# ASR Providers

Douvo supports three Doubao ASR recognition paths: `Web`, `Android`, and `Mix`. Choose the path in **Settings... -> Account -> ASR Provider**. The default provider is `Web`.

All paths are based on observed Doubao client behavior, not an official public Doubao API. Any path may break if Doubao changes authentication, risk controls, WebSocket protocols, audio formats, or response payloads.

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

The token is read from `data.settings.asr_config.app_key`. The complete Android credential set is saved locally:

```text
~/Library/Application Support/Douvo/android_asr_credentials.json
```

Clicking **Reset Android Credentials** in Settings deletes this file. The next Android-provider run generates a new local identity and registers again, so Doubao will see it as a new IME-style device.

### WebSocket and Protocol

The Android provider connects to:

```text
wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws?aid=401734&device_id=<deviceId>
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
| `StartTask` | Creates an ASR task with the ASR token |
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
    "enable_asr_twopass": true,
    "enable_asr_threepass": true,
    "input_mode": "tool"
  }
}
```

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

## Mix Provider

The Mix provider runs the Web and Android providers at the same time, then asks AI post-processing to merge the two recognition results into one final text.

Mix mode requires:

- Web ASR login to be valid.
- Android ASR credentials to be available or creatable.
- AI post-processing to be enabled.

During recording, the same microphone capture is converted into both required audio formats:

```text
AVAudioEngine -> 16 kHz mono PCM -> Web ASR
                         |
                         -> AudioToolbox Opus encoder -> Android ASR
```

Douvo keeps separate transcript accumulators for `web` and `android` so the two providers do not overwrite each other's intermediate results. On completion, if both paths produced text, the correction prompt includes:

- Recognition result 1: Doubao Web
- Recognition result 2: Doubao Android

The model is instructed to combine overlapping content, use either path to fill obvious omissions or misrecognitions, and avoid duplicate output. If only one path produced text, Douvo falls back to the single available transcript. If the correction backend cannot run, the fallback text is the preferred single ASR transcript rather than the labeled two-result prompt.

## Comparison

| Item | Web | Android | Mix |
| --- | --- | --- | --- |
| Entry point | Doubao Web ASR | Doubao IME Android ASR | Web + Android |
| Requires WebView login | Yes | No | Yes |
| Requires AI post-processing | No | No | Yes |
| Local identity | Doubao cookies, `device_id`, `web_id` | `cdid`, `openudid`, `clientudid`, `deviceId`, `installId`, ASR token | Both |
| Local credential file | `asr_params.json` | `android_asr_credentials.json` | Both |
| ASR host | `ws-samantha.doubao.com` | `frontier-audio-ime-ws.doubao.com` | Both |
| Message format | JSON control frames + binary PCM audio frames | Protobuf task/session messages + Opus audio frames | Both |
| Audio format | 16 kHz mono PCM | 16 kHz mono Opus | Both |
| Common failures | Expired login, incomplete cookies, changed web fields | Device registration failure, token fetch failure, Protobuf or risk-control changes | Any single-provider failure, correction backend unavailable |

## Network Notes

The Android provider needs these domains to be reachable:

```text
log.snssdk.com
is.snssdk.com
frontier-audio-ime-ws.doubao.com
```

`log.snssdk.com` is commonly matched by ad-blocking rules. If a router, proxy, OpenClash, or fake-ip setup redirects or blocks it, device registration can fail. In the app log, this often appears as a TLS connection failure. When this happens, check ad filters, rule sets, and DNS fake-ip policies for the domains above.

The Web provider needs normal access to Doubao Web and `ws-samantha.doubao.com`, and the locally saved cookies must still be valid.

## Privacy and Risk

- Both providers send microphone audio to Doubao servers for recognition.
- The Web provider stores web login parameters; the Android provider stores IME-style device credentials and an ASR token.
- Do not commit or share `asr_params.json`, `android_asr_credentials.json`, or credential values copied from logs.
- Neither provider is an official stable API, so both may require future maintenance when Doubao changes client or server behavior.
