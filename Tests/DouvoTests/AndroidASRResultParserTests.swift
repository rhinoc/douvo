import XCTest
@testable import Douvo

final class AndroidASRResultParserTests: XCTestCase {
    func testAndroidClientIdentityUsesCurrentDoubaoIMEVersion() {
        XCTAssertEqual(
            DoubaoAndroidClientIdentity.webSocketURL.absoluteString,
            "wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws"
        )
        XCTAssertEqual(DoubaoAndroidClientIdentity.versionCode, "100316010")
        XCTAssertEqual(DoubaoAndroidClientIdentity.versionName, "1.3.16")
        XCTAssertTrue(
            DoubaoAndroidClientIdentity.userAgent.hasPrefix(
                "com.bytedance.android.doubaoime/100316010 "
            )
        )
    }

    func testAndroidCredentialDiagnosticsDoNotExposeCredentialValues() {
        let credentials = DoubaoAndroidCredentials(
            deviceId: "device-secret",
            installId: "install-secret",
            cdid: "cdid-secret",
            openudid: "openudid-secret",
            clientudid: "clientudid-secret",
            token: "app-key-secret"
        )

        let diagnostics = DoubaoAndroidClientIdentity.credentialDiagnostics(credentials)
            + " "
            + DoubaoAndroidClientIdentity.frontierQueryDiagnostics(credentials: credentials)

        XCTAssertFalse(diagnostics.contains("device-secret"))
        XCTAssertFalse(diagnostics.contains("install-secret"))
        XCTAssertFalse(diagnostics.contains("cdid-secret"))
        XCTAssertFalse(diagnostics.contains("openudid-secret"))
        XCTAssertFalse(diagnostics.contains("clientudid-secret"))
        XCTAssertFalse(diagnostics.contains("app-key-secret"))
        XCTAssertFalse(diagnostics.contains("Fingerprint"))
        XCTAssertTrue(diagnostics.contains("deviceIDSet=true"))
        XCTAssertTrue(diagnostics.contains("appKeySet=true"))
        XCTAssertTrue(diagnostics.contains("missingRequired=none"))
    }

    func testFrontierQueryIncludesCurrentClientIdentity() {
        let credentials = DoubaoAndroidCredentials(
            deviceId: "device-123",
            installId: "install-456",
            cdid: "cdid",
            openudid: "openudid",
            clientudid: "clientudid",
            token: "token"
        )
        let query = Dictionary(
            uniqueKeysWithValues: DoubaoAndroidClientIdentity
                .frontierQueryItems(credentials: credentials)
                .map { ($0.name, $0.value ?? "") }
        )

        XCTAssertEqual(query["aid"], "401734")
        XCTAssertEqual(query["app_name"], "oime")
        XCTAssertEqual(query["did"], "device-123")
        XCTAssertNil(query["device_id"])
        XCTAssertEqual(query["iid"], "install-456")
        XCTAssertEqual(query["install_id"], "install-456")
        XCTAssertEqual(query["version_code"], "100316010")
        XCTAssertEqual(query["update_version_code"], "100316010")
        XCTAssertEqual(query["version_name"], "1.3.16")
        XCTAssertEqual(query["user_agent"], "")
        XCTAssertEqual(query["forwarded"], "")
        XCTAssertEqual(query["target"], "")
        XCTAssertEqual(query["mobile"], "")
        XCTAssertEqual(query["token"], DoubaoAndroidClientIdentity.authenticationToken(deviceID: "device-123"))
    }

    func testTransportTokenIsSeparateFromControlRequestAppKey() throws {
        let authenticationToken = DoubaoAndroidClientIdentity.authenticationToken(
            deviceID: "device-123"
        )
        let request = AndroidASRProtobuf.request(
            appKey: "app-key",
            methodName: "StartTask",
            payload: "",
            audioData: Data(),
            requestID: "request-id",
            frameState: 0
        )
        let tokenObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(authenticationToken.utf8)) as? [String: String]
        )

        XCTAssertEqual(tokenObject["device_id"], "device-123")
        XCTAssertEqual(tokenObject["aid"], "401734")

        var expectedPrefix = Data([0x12, 0x07])
        expectedPrefix.append(Data("app-key".utf8))
        XCTAssertTrue(request.starts(with: expectedPrefix))
    }

    func testSessionFailurePreservesConcurrencyQuotaStatusCode() {
        var data = Data()
        appendTestProtoString("SessionFailed", fieldNumber: 4, to: &data)
        appendTestProtoVarint(
            UInt64(AndroidASRErrorClassifier.concurrencyQuotaStatusCode),
            fieldNumber: 5,
            to: &data
        )
        appendTestProtoString(
            "concurrency quota exceeded: key:example,value:5",
            fieldNumber: 6,
            to: &data
        )

        let response = AndroidASRProtobuf.parseResponse(data)

        guard case .error(let message, let statusCode, let metadata) = response.type else {
            return XCTFail("Expected SessionFailed response")
        }
        XCTAssertEqual(statusCode, AndroidASRErrorClassifier.concurrencyQuotaStatusCode)
        XCTAssertEqual(message, "concurrency quota exceeded: key:example,value:5")
        XCTAssertEqual(metadata["android_response_status_code"], "40200011")
    }

    func testSessionFailurePreservesAuthenticationMessageAndStatusCode() {
        var data = Data()
        appendTestProtoString("SessionFailed", fieldNumber: 4, to: &data)
        appendTestProtoVarint(40000000, fieldNumber: 5, to: &data)
        appendTestProtoString("authentication failed: token expired", fieldNumber: 6, to: &data)

        let response = AndroidASRProtobuf.parseResponse(data)

        guard case .error(let message, let statusCode, let metadata) = response.type else {
            return XCTFail("Expected authentication SessionFailed response")
        }
        XCTAssertEqual(message, "authentication failed: token expired")
        XCTAssertEqual(statusCode, 40000000)
        XCTAssertEqual(metadata["android_response_message_type"], "SessionFailed")
        XCTAssertEqual(metadata["android_response_status_code"], "40000000")
    }

    func testSessionConfigEnablesAndroidCorrectionPasses() throws {
        let config = AndroidASRSessionConfig.make(
            deviceID: "device-123",
            context: "encoded-context"
        )
        let extra = try XCTUnwrap(config["extra"] as? [String: Any])

        XCTAssertEqual(extra["did"] as? String, "device-123")
        XCTAssertEqual(extra["context"] as? String, "encoded-context")
        XCTAssertEqual(extra["app_version"] as? String, "1.3.16")
        XCTAssertEqual(extra["enable_asr_threepass"] as? Bool, true)
        XCTAssertEqual(extra["enable_asr_twopass"] as? Bool, true)
        XCTAssertEqual(extra["strong_ddc"] as? Bool, true)
        XCTAssertEqual(extra["use_twopass_retry"] as? Bool, true)
        XCTAssertEqual(extra["enable_text_post_process"] as? Bool, true)
        XCTAssertEqual(extra["asr_text_post_process_type"] as? String, "last_post_process")
        XCTAssertEqual(extra["disable_user_words"] as? Bool, true)
        XCTAssertEqual(extra["enable_print_chinese"] as? Bool, false)
        XCTAssertEqual(extra["aid"] as? String, "401734")
        XCTAssertEqual(extra["version_code"] as? String, "100316010")
        XCTAssertEqual(extra["update_version_code"] as? String, "100316010")
        XCTAssertEqual(extra["version_name"] as? String, "1.3.16")
    }

    func testSessionConfigEnablesUploadedPersonalLexicon() throws {
        let config = AndroidASRSessionConfig.make(
            deviceID: "123",
            usePersonalLexicon: true
        )
        let extra = try XCTUnwrap(config["extra"] as? [String: Any])

        XCTAssertEqual(extra["disable_user_words"] as? Bool, false)
    }

    func testSessionConfigOmitsEmptyContext() throws {
        let config = AndroidASRSessionConfig.make(deviceID: "device-123")
        let extra = try XCTUnwrap(config["extra"] as? [String: Any])

        XCTAssertNil(extra["context"])
    }

    func testFinalTaskRequestPayloadFinishesAudioAndForcesTwoPass() throws {
        let payload = AndroidASRTaskRequestPayload.make(timestampMillis: 123_456, isFinal: true)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        )
        let extra = try XCTUnwrap(object["extra"] as? [String: Any])

        XCTAssertEqual(object["timestamp_ms"] as? Int, 123_456)
        XCTAssertEqual(extra["finish_audio"] as? Bool, true)
        XCTAssertEqual(extra["force_asr_twopass"] as? Bool, true)
    }

    func testStreamingTaskRequestPayloadDoesNotSignalFinish() throws {
        let payload = AndroidASRTaskRequestPayload.make(timestampMillis: 42, isFinal: false)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        )
        let extra = try XCTUnwrap(object["extra"] as? [String: Any])

        XCTAssertEqual(object["timestamp_ms"] as? Int, 42)
        XCTAssertTrue(extra.isEmpty)
    }

    func testFinishCoordinatorRequestsFinishImmediatelyAfterFinalAudioFrame() {
        var coordinator = AndroidASRFinishCoordinator()

        XCTAssertEqual(coordinator.finalFrameDidSend(), .finalFrameSent)
        XCTAssertTrue(coordinator.finalFrameSent)
        XCTAssertTrue(coordinator.finishSessionRequested)
        XCTAssertEqual(coordinator.finishTrigger, .finalFrameSent)
    }

    func testFinishCoordinatorRecordsFinalResultAfterFinishWasRequested() throws {
        var coordinator = AndroidASRFinishCoordinator()
        XCTAssertEqual(coordinator.finalFrameDidSend(), .finalFrameSent)

        let finalResult = try XCTUnwrap(AndroidASRProtobuf.parseRecognitionResultJSON("""
        {
          "results": [
            {
              "text": "从最新主干创建一个 worktree。",
              "is_interim": false,
              "is_vad_finished": true,
              "extra": { "nonstream_result": true }
            }
          ]
        }
        """))

        coordinator.receive(finalResult)
        XCTAssertTrue(coordinator.finalResultReceived)
        XCTAssertTrue(coordinator.finishSessionRequested)
        XCTAssertEqual(coordinator.finishTrigger, .finalFrameSent)
    }

    func testFinishCoordinatorDoesNotRecordInterimAsFinal() throws {
        var coordinator = AndroidASRFinishCoordinator()

        let interimResult = try XCTUnwrap(AndroidASRProtobuf.parseRecognitionResultJSON("""
        {
          "results": [
            {
              "text": "从最新的主干拉个 walk tree",
              "is_interim": true
            }
          ]
        }
        """))

        coordinator.receive(interimResult)
        XCTAssertFalse(coordinator.finalResultReceived)
        XCTAssertFalse(coordinator.finishSessionRequested)
    }

    func testFinishCoordinatorRequestsFinishOnlyOnce() {
        var coordinator = AndroidASRFinishCoordinator()

        XCTAssertEqual(coordinator.finalFrameDidSend(), .finalFrameSent)
        XCTAssertTrue(coordinator.finishSessionRequested)
        XCTAssertNil(coordinator.finalFrameDidSend())
    }

    func testParserJoinsLegacySegmentedResults() {
        let json = """
        {
          "results": [
            {
              "text": "我发现诊断页它有一个选择 backend 的地方",
              "is_interim": true
            },
            {
              "text": "然后下拉菜单里的 checkmark 可以放在右边吗",
              "is_interim": true
            },
            {
              "text": "G 你可以叫 model",
              "is_interim": true
            }
          ]
        }
        """

        let result = AndroidASRProtobuf.parseRecognitionResultJSON(json)

        XCTAssertEqual(
            result?.text,
            "我发现诊断页它有一个选择 backend 的地方然后下拉菜单里的 checkmark 可以放在右边吗 G 你可以叫 model"
        )
        XCTAssertEqual(result?.provider, "android")
        XCTAssertEqual(result?.kind, "interim")
        XCTAssertEqual(result?.segmentCount, 3)
        XCTAssertEqual(result?.metadata["android_result_segments"], "3")
        XCTAssertEqual(result?.metadata["android_text_segments"], "3")
        XCTAssertEqual(result?.metadata["android_result_model"], "segmented")
    }

    func testParserUsesCumulativeResultWithoutAppendingSentenceDetails() {
        let json = """
        {
          "results": [
            {
              "text": "今天天气真不错。我们",
              "start_time": 0,
              "end_time": 7020,
              "is_interim": true
            },
            {
              "text": "今天天气真不错。",
              "start_time": 0,
              "end_time": 2500,
              "is_interim": false,
              "stream_asr_finish": true,
              "extra": { "nonstream_result": true }
            },
            {
              "text": "我们",
              "start_time": 6520,
              "end_time": 7020,
              "is_interim": true,
              "stream_asr_finish": false
            }
          ]
        }
        """

        let result = AndroidASRProtobuf.parseRecognitionResultJSON(json)

        XCTAssertEqual(result?.text, "今天天气真不错。我们")
        XCTAssertEqual(result?.segments.count, 1)
        XCTAssertEqual(result?.segmentCount, 3)
        XCTAssertEqual(result?.isFinal, false)
        XCTAssertEqual(result?.metadata["android_result_model"], "cumulative_with_details")
        XCTAssertEqual(result?.metadata["android_detail_segments"], "2")
        XCTAssertEqual(result?.metadata["android_nonstream_result"], "false")
        XCTAssertEqual(result?.metadata["android_raw_nonstream_result_segments"], "1")
    }

    func testAssemblerSwitchesToCumulativeSnapshotsAfterDetailedFrame() {
        var assembler = AndroidASRTranscriptAssembler()
        let initial = AndroidASRProtobuf.parseRecognitionResultJSON("""
        {
          "results": [
            {
              "text": "今天天气真不错。",
              "start_time": 0,
              "end_time": 2500,
              "is_interim": true
            }
          ]
        }
        """)!
        let detailed = AndroidASRProtobuf.parseRecognitionResultJSON("""
        {
          "results": [
            {
              "text": "今天天气真不错。我们",
              "start_time": 0,
              "end_time": 7020,
              "is_interim": true
            },
            {
              "text": "今天天气真不错。",
              "start_time": 0,
              "end_time": 2500,
              "is_interim": false,
              "stream_asr_finish": true,
              "extra": { "nonstream_result": true }
            },
            {
              "text": "我们",
              "start_time": 6520,
              "end_time": 7020,
              "is_interim": true,
              "stream_asr_finish": false
            }
          ]
        }
        """)!
        let finalRevision = AndroidASRProtobuf.parseRecognitionResultJSON("""
        {
          "results": [
            {
              "text": "今天天气不错，我们。",
              "start_time": 0,
              "end_time": 7200,
              "is_interim": false,
              "is_vad_finished": true
            }
          ]
        }
        """)!

        _ = assembler.update(with: initial)
        let detailedUpdate = assembler.update(with: detailed)
        let finalUpdate = assembler.update(with: finalRevision)

        XCTAssertEqual(detailedUpdate.text, "今天天气真不错。我们")
        XCTAssertEqual(finalUpdate.text, "今天天气不错，我们。")
        XCTAssertEqual(finalUpdate.metadata["android_transcript_model"], "cumulative")
        XCTAssertEqual(finalUpdate.isFinal, true)
    }

    func testParserRecordsSegmentTimingMetadataForDiagnostics() {
        let json = """
        {
          "results": [
            {
              "index": 0,
              "start_time": 120,
              "end_time": 840,
              "text": "第一段",
              "is_interim": true
            },
            {
              "index": 1,
              "start_time": 900,
              "end_time": 1420,
              "text": "第二段",
              "is_interim": true
            }
          ]
        }
        """

        let result = AndroidASRProtobuf.parseRecognitionResultJSON(json)

        XCTAssertEqual(result?.metadata["android_segment_indices"], "0,1")
        XCTAssertEqual(result?.metadata["android_segment_start_times"], "120,900")
        XCTAssertEqual(result?.metadata["android_segment_end_times"], "840,1420")
        XCTAssertEqual(result?.metadata["android_segment_time_ranges"], "120-840,900-1420")
    }

    func testParserMarksNonstreamResultAsFinal() {
        let json = """
        {
          "results": [
            {
              "text": "测试测试。",
              "is_interim": false,
              "is_vad_finished": true,
              "extra": {
                "nonstream_result": true
              }
            }
          ]
        }
        """

        let result = AndroidASRProtobuf.parseRecognitionResultJSON(json)

        XCTAssertEqual(result?.text, "测试测试。")
        XCTAssertEqual(result?.kind, "final")
        XCTAssertEqual(result?.isFinal, true)
        XCTAssertEqual(result?.metadata["android_nonstream_result"], "true")
    }

    func testParserMarksLastPostProcessSnapshotFinalWithoutVADFlag() {
        let json = """
        {
          "results": [
            {
              "text": "今天这个方案已经确定了，我们明天开始实施。",
              "start_time": 0,
              "end_time": 5.74,
              "is_interim": false
            }
          ]
        }
        """

        let result = AndroidASRProtobuf.parseRecognitionResultJSON(json)

        XCTAssertEqual(result?.text, "今天这个方案已经确定了，我们明天开始实施。")
        XCTAssertEqual(result?.kind, "final")
        XCTAssertEqual(result?.isFinal, true)
        XCTAssertEqual(result?.metadata["android_vad_finished_segments"], "0")
    }

    func testAssemblerReplacesSameIndexedSegmentInsteadOfAppendingDuplicate() {
        var assembler = AndroidASRTranscriptAssembler()
        let first = AndroidASRProtobuf.parseRecognitionResultJSON("""
        {
          "results": [
            {
              "index": 0,
              "start_time": 0,
              "end_time": 1000,
              "text": "后一段 manage 这边也要做安全网",
              "is_interim": true
            }
          ]
        }
        """)!
        let second = AndroidASRProtobuf.parseRecognitionResultJSON("""
        {
          "results": [
            {
              "index": 0,
              "start_time": 0,
              "end_time": 1400,
              "text": "后一段 manager 这边也要做安全网 transcription manager",
              "is_interim": true
            }
          ]
        }
        """)!

        _ = assembler.update(with: first)
        let update = assembler.update(with: second)

        XCTAssertEqual(update.text, "后一段 manager 这边也要做安全网 transcription manager")
        XCTAssertEqual(update.metadata["android_assembled_segments"], "1")
    }

    func testAssemblerKeepsSameIndexSegmentsWithDifferentStartTimes() {
        var assembler = AndroidASRTranscriptAssembler()
        let first = AndroidASRProtobuf.parseRecognitionResultJSON("""
        {
          "results": [
            {
              "index": 0,
              "start_time": 0,
              "end_time": 36,
              "text": "普通用户基本用不到 replace 正常打开 APP 会直接进 UI",
              "is_interim": true
            }
          ]
        }
        """)!
        let second = AndroidASRProtobuf.parseRecognitionResultJSON("""
        {
          "results": [
            {
              "index": 0,
              "start_time": 36,
              "end_time": 84,
              "text": "前和现在的修正结果也不是普通录音流程的一部分",
              "is_interim": false,
              "is_vad_finished": true
            }
          ]
        }
        """)!

        _ = assembler.update(with: first)
        let update = assembler.update(with: second)

        XCTAssertEqual(
            update.text,
            "普通用户基本用不到 replace 正常打开 APP 会直接进 UI 前和现在的修正结果也不是普通录音流程的一部分"
        )
        XCTAssertEqual(update.metadata["android_assembled_segment_ids"], "start:0,start:36")
        XCTAssertEqual(update.metadata["android_assembled_segments"], "2")
    }

    func testAssemblerCoalescesOverlappingSameIndexTimeWindows() {
        var assembler = AndroidASRTranscriptAssembler()
        let first = AndroidASRProtobuf.parseRecognitionResultJSON("""
        {
          "results": [
            {
              "index": 0,
              "start_time": 20,
              "end_time": 73,
              "text": "到的是 logs Douvel Replay 用途是重新跑 correction",
              "is_interim": true
            }
          ]
        }
        """)!
        let second = AndroidASRProtobuf.parseRecognitionResultJSON("""
        {
          "results": [
            {
              "index": 0,
              "start_time": 22,
              "end_time": 73,
              "text": "到的是 logs Douvel Replay 用途是重新跑 correction 对比之前和现在的修正结果",
              "is_interim": true
            }
          ]
        }
        """)!

        _ = assembler.update(with: first)
        let update = assembler.update(with: second)

        XCTAssertEqual(
            update.text,
            "到的是 logs Douvel Replay 用途是重新跑 correction 对比之前和现在的修正结果"
        )
        XCTAssertEqual(update.metadata["android_assembled_segment_ids"], "start:20")
        XCTAssertEqual(update.metadata["android_assembled_segments"], "1")
        XCTAssertEqual(update.metadata["android_overlapped_segment_update_count"], "1")
    }

    func testAssemblerMergesSlidingActiveWindowInsteadOfKeepingShorterOlderText() {
        var assembler = AndroidASRTranscriptAssembler()
        let first = AndroidASRProtobuf.parseRecognitionResultJSON("""
        {
          "results": [
            {
              "index": 0,
              "start_time": 18,
              "end_time": 73,
              "text": "active segment 是当前 ASR 还在重写的候选内容 final 是同",
              "is_interim": true
            }
          ]
        }
        """)!
        let second = AndroidASRProtobuf.parseRecognitionResultJSON("""
        {
          "results": [
            {
              "index": 0,
              "start_time": 36,
              "end_time": 101,
              "text": "final 是同一窗口时确认 active 后提交 后续窗口会先提交旧 active",
              "is_interim": true
            }
          ]
        }
        """)!

        _ = assembler.update(with: first)
        let update = assembler.update(with: second)

        XCTAssertEqual(
            update.text,
            "active segment 是当前 ASR 还在重写的候选内容 final 是同一窗口时确认 active 后提交 后续窗口会先提交旧 active"
        )
        XCTAssertEqual(update.metadata["android_assembled_segment_ids"], "start:18")
        XCTAssertEqual(update.metadata["android_assembled_segments"], "1")
        XCTAssertEqual(update.metadata["android_ime_active_range"], "18-101")
    }

    func testAssemblerCommitsAdjacentWindowsInStreamingOrder() {
        var assembler = AndroidASRTranscriptAssembler()
        let first = AndroidASRProtobuf.parseRecognitionResultJSON("""
        {
          "results": [
            {
              "index": 0,
              "start_time": 0,
              "end_time": 1000,
              "text": "第一段",
              "is_interim": true
            }
          ]
        }
        """)!
        let second = AndroidASRProtobuf.parseRecognitionResultJSON("""
        {
          "results": [
            {
              "index": 0,
              "start_time": 1000,
              "end_time": 2000,
              "text": "第二段",
              "is_interim": true
            }
          ]
        }
        """)!

        _ = assembler.update(with: first)
        let update = assembler.update(with: second)

        XCTAssertEqual(update.text, "第一段第二段")
        XCTAssertEqual(update.metadata["android_assembled_segments"], "2")
    }
}

private func appendTestProtoString(_ value: String, fieldNumber: Int, to data: inout Data) {
    let bytes = Data(value.utf8)
    appendTestProtoVarint(UInt64(fieldNumber << 3 | 2), to: &data)
    appendTestProtoVarint(UInt64(bytes.count), to: &data)
    data.append(bytes)
}

private func appendTestProtoVarint(
    _ value: UInt64,
    fieldNumber: Int? = nil,
    to data: inout Data
) {
    if let fieldNumber {
        appendTestProtoVarint(UInt64(fieldNumber << 3), to: &data)
    }
    var remaining = value
    while remaining >= 0x80 {
        data.append(UInt8(remaining & 0x7f) | 0x80)
        remaining >>= 7
    }
    data.append(UInt8(remaining))
}
