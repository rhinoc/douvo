import Foundation

struct ASRLabOptions: Equatable {
    let audioURL: URL
    let provider: ASRProvider
    let context: String
    let vocabulary: String
}

enum ASRLabCommand {
    static func options(from arguments: [String]) throws -> ASRLabOptions {
        guard let commandIndex = arguments.firstIndex(of: "--asr-lab"),
              arguments.indices.contains(commandIndex + 1) else {
            throw commandError("Usage: Douvo --asr-lab <audio-file> [--provider web|android|mix] [--vocabulary <terms>]")
        }

        let audioURL = URL(fileURLWithPath: arguments[commandIndex + 1])
        let provider: ASRProvider
        if let providerIndex = arguments.firstIndex(of: "--provider") {
            guard arguments.indices.contains(providerIndex + 1),
                  let parsed = ASRProvider(rawValue: arguments[providerIndex + 1]) else {
                throw commandError("Invalid ASR provider; expected web, android, or mix")
            }
            provider = parsed
        } else {
            provider = .android
        }

        let context: String
        if let contextIndex = arguments.firstIndex(of: "--context") {
            guard arguments.indices.contains(contextIndex + 1) else {
                throw commandError("Missing value after --context")
            }
            context = arguments[contextIndex + 1]
        } else {
            context = ""
        }

        let vocabulary: String
        if let vocabularyIndex = arguments.firstIndex(of: "--vocabulary") {
            guard arguments.indices.contains(vocabularyIndex + 1) else {
                throw commandError("Missing value after --vocabulary")
            }
            vocabulary = arguments[vocabularyIndex + 1]
        } else {
            vocabulary = ""
        }

        return ASRLabOptions(
            audioURL: audioURL,
            provider: provider,
            context: context,
            vocabulary: vocabulary
        )
    }

    static func run(arguments: [String]) async -> Int32 {
        do {
            let options = try options(from: arguments)
            guard FileManager.default.fileExists(atPath: options.audioURL.path) else {
                throw commandError("ASR lab audio file does not exist: \(options.audioURL.path)")
            }

            let result = try await ASRDemoDiagnosticRunner.run(
                provider: options.provider,
                audioURL: options.audioURL,
                androidContext: options.context,
                androidVocabulary: options.vocabulary
            )
            print("ASR lab result: \(result.summary)")
            for provider in result.transcriptsByProvider.keys.sorted() {
                print("ASR lab transcript [\(provider)]: \(result.transcriptsByProvider[provider] ?? "")")
            }
            return result.isHealthy ? 0 : 1
        } catch {
            fputs("ASR lab failed: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func commandError(_ description: String) -> NSError {
        NSError(
            domain: "Douvo.ASRLab",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}
