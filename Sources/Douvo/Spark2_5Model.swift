import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// Swift/MLX implementation of the Spark-X2.5 decoder architecture.
///
/// Spark alternates three sliding-window attention layers with one full
/// attention layer.  The model also applies a sigmoid gate independently to
/// each attention head, so it cannot be loaded through one of the existing
/// Qwen/Llama model registrations.
struct Spark2_5Configuration: Codable, Sendable {
    let modelType: String
    let hiddenSize: Int
    let intermediateSize: Int
    let hiddenLayers: Int
    let attentionHeads: Int
    let kvHeads: Int
    let headDim: Int
    let vocabularySize: Int
    let layerTypes: [String]
    let ropeParameters: [String: [String: StringOrNumber]]
    let slidingWindow: Int
    let rmsNormEps: Float
    let maxPositionEmbeddings: Int
    let attentionBias: Bool
    let mlpBias: Bool
    let hiddenAct: String
    let gateAttnActMode: String
    let headwiseAttnOutputGate: Bool
    let tieWordEmbeddings: Bool

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case hiddenSize = "hidden_size"
        case intermediateSize = "intermediate_size"
        case hiddenLayers = "num_hidden_layers"
        case attentionHeads = "num_attention_heads"
        case kvHeads = "num_key_value_heads"
        case headDim = "head_dim"
        case vocabularySize = "vocab_size"
        case layerTypes = "layer_types"
        case ropeParameters = "rope_parameters"
        case slidingWindow = "sliding_window"
        case rmsNormEps = "rms_norm_eps"
        case maxPositionEmbeddings = "max_position_embeddings"
        case attentionBias = "attention_bias"
        case mlpBias = "mlp_bias"
        case hiddenAct = "hidden_act"
        case gateAttnActMode = "gate_attn_act_mode"
        case headwiseAttnOutputGate = "headwise_attn_output_gate"
        case tieWordEmbeddings = "tie_word_embeddings"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelType = try container.decode(String.self, forKey: .modelType)
        hiddenSize = try container.decode(Int.self, forKey: .hiddenSize)
        intermediateSize = try container.decode(Int.self, forKey: .intermediateSize)
        hiddenLayers = try container.decode(Int.self, forKey: .hiddenLayers)
        attentionHeads = try container.decode(Int.self, forKey: .attentionHeads)
        kvHeads = try container.decode(Int.self, forKey: .kvHeads)
        headDim = try container.decode(Int.self, forKey: .headDim)
        vocabularySize = try container.decode(Int.self, forKey: .vocabularySize)
        layerTypes = try container.decode([String].self, forKey: .layerTypes)
        ropeParameters = try container.decode(
            [String: [String: StringOrNumber]].self,
            forKey: .ropeParameters
        )
        slidingWindow = try container.decode(Int.self, forKey: .slidingWindow)
        rmsNormEps = try container.decodeIfPresent(Float.self, forKey: .rmsNormEps) ?? 1e-6
        maxPositionEmbeddings = try container.decodeIfPresent(
            Int.self,
            forKey: .maxPositionEmbeddings
        ) ?? 8_192
        attentionBias = try container.decodeIfPresent(Bool.self, forKey: .attentionBias) ?? false
        mlpBias = try container.decodeIfPresent(Bool.self, forKey: .mlpBias) ?? false
        hiddenAct = try container.decodeIfPresent(String.self, forKey: .hiddenAct) ?? "gelu"
        gateAttnActMode = try container.decodeIfPresent(
            String.self,
            forKey: .gateAttnActMode
        ) ?? "sigmoid"
        headwiseAttnOutputGate = try container.decodeIfPresent(
            Bool.self,
            forKey: .headwiseAttnOutputGate
        ) ?? true
        tieWordEmbeddings = try container.decodeIfPresent(
            Bool.self,
            forKey: .tieWordEmbeddings
        ) ?? true

        guard modelType == "spark2_5" else {
            throw Spark2_5ModelError.unsupportedModelType(modelType)
        }
        guard layerTypes.count == hiddenLayers else {
            throw Spark2_5ModelError.invalidLayerConfiguration
        }
        guard layerTypes.allSatisfy({ $0 == "full_attention" || $0 == "sliding_attention" }) else {
            throw Spark2_5ModelError.invalidLayerConfiguration
        }
        guard hiddenAct == "gelu", gateAttnActMode == "sigmoid", headwiseAttnOutputGate else {
            throw Spark2_5ModelError.unsupportedConfiguration
        }
    }
}

private enum Spark2_5ModelError: LocalizedError {
    case unsupportedModelType(String)
    case invalidLayerConfiguration
    case unsupportedConfiguration

    var errorDescription: String? {
        switch self {
        case .unsupportedModelType(let modelType):
            "Unsupported Spark model type: \(modelType)"
        case .invalidLayerConfiguration:
            "Spark model layer configuration is invalid."
        case .unsupportedConfiguration:
            "This Spark model uses an unsupported activation or attention gate."
        }
    }
}

fileprivate final class Spark2_5Attention: Module {
    private let args: Spark2_5Configuration
    private let headCount: Int
    private let keyValueHeadCount: Int
    private let headDimension: Int
    private let scale: Float
    let isSliding: Bool

    @ModuleInfo(key: "q_k_v_proj") var qKVProjection: Linear
    @ModuleInfo(key: "g_proj") var attentionGate: Linear
    @ModuleInfo(key: "out_proj") var outputProjection: Linear

    private let rope: RoPELayer

    init(_ args: Spark2_5Configuration, layerIndex: Int) {
        self.args = args
        self.headCount = args.attentionHeads
        self.keyValueHeadCount = args.kvHeads
        self.headDimension = args.headDim
        self.scale = pow(Float(args.headDim), -0.5)
        self.isSliding = args.layerTypes[layerIndex] == "sliding_attention"

        let querySize = args.attentionHeads * args.headDim
        let keyValueSize = args.kvHeads * args.headDim
        self._qKVProjection.wrappedValue = Linear(
            args.hiddenSize,
            querySize + 2 * keyValueSize,
            bias: args.attentionBias
        )
        self._attentionGate.wrappedValue = Linear(
            args.hiddenSize,
            args.attentionHeads,
            bias: args.attentionBias
        )
        self._outputProjection.wrappedValue = Linear(
            querySize,
            args.hiddenSize,
            bias: args.attentionBias
        )

        let layerType = args.layerTypes[layerIndex]
        let ropeConfig = args.ropeParameters[layerType] ?? [:]
        let ropeTheta = ropeConfig["rope_theta"]?.asFloat() ?? 10_000
        let partialRotaryFactor = ropeConfig["partial_rotary_factor"]?.asFloat() ?? 1
        self.rope = initializeRope(
            dims: Int(Float(args.headDim) * partialRotaryFactor),
            base: ropeTheta,
            traditional: false,
            scalingConfig: nil,
            maxPositionEmbeddings: args.maxPositionEmbeddings
        )
    }

    func callAsFunction(
        _ x: MLXArray,
        mask: MLXFast.ScaledDotProductAttentionMaskMode,
        cache: KVCache?
    ) -> MLXArray {
        let batchSize = x.dim(0)
        let sequenceLength = x.dim(1)
        let querySize = headCount * headDimension
        let keyValueSize = keyValueHeadCount * headDimension

        let qkv = qKVProjection(x)
        let parts = split(qkv, indices: [querySize, querySize + keyValueSize], axis: -1)
        var queries = parts[0]
        var keys = parts[1]
        var values = parts[2]

        queries = queries
            .reshaped(batchSize, sequenceLength, headCount, headDimension)
            .transposed(0, 2, 1, 3)
        keys = keys
            .reshaped(batchSize, sequenceLength, keyValueHeadCount, headDimension)
            .transposed(0, 2, 1, 3)
        values = values
            .reshaped(batchSize, sequenceLength, keyValueHeadCount, headDimension)
            .transposed(0, 2, 1, 3)

        queries = contiguous(queries)
        keys = contiguous(keys)
        values = contiguous(values)

        queries = applyRotaryPosition(rope, to: queries, cache: cache)
        keys = applyRotaryPosition(rope, to: keys, cache: cache)

        var output = attentionWithCacheUpdate(
            queries: queries,
            keys: keys,
            values: values,
            cache: cache,
            scale: scale,
            mask: mask
        )
        output = output.transposed(0, 2, 1, 3)

        let gate = sigmoid(attentionGate(x).asType(.float32)).asType(output.dtype)
        output = output * gate.expandedDimensions(axis: -1)
        return outputProjection(output.reshaped(batchSize, sequenceLength, -1))
    }
}

fileprivate final class Spark2_5MLP: Module, UnaryLayer {
    @ModuleInfo(key: "gate_proj") var gateProjection: Linear
    @ModuleInfo(key: "up_proj") var upProjection: Linear
    @ModuleInfo(key: "down_proj") var downProjection: Linear

    init(_ args: Spark2_5Configuration) {
        self._gateProjection.wrappedValue = Linear(
            args.hiddenSize,
            args.intermediateSize,
            bias: args.mlpBias
        )
        self._upProjection.wrappedValue = Linear(
            args.hiddenSize,
            args.intermediateSize,
            bias: args.mlpBias
        )
        self._downProjection.wrappedValue = Linear(
            args.intermediateSize,
            args.hiddenSize,
            bias: args.mlpBias
        )
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        downProjection(gelu(gateProjection(x)) * upProjection(x))
    }
}

fileprivate final class Spark2_5TransformerBlock: Module {
    @ModuleInfo(key: "self_attn") var attention: Spark2_5Attention
    @ModuleInfo(key: "mlp") var mlp: Spark2_5MLP
    @ModuleInfo(key: "input_layernorm") var inputLayerNorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayerNorm: RMSNorm

    init(_ args: Spark2_5Configuration, layerIndex: Int) {
        self._attention.wrappedValue = Spark2_5Attention(args, layerIndex: layerIndex)
        self._mlp.wrappedValue = Spark2_5MLP(args)
        self._inputLayerNorm.wrappedValue = RMSNorm(
            dimensions: args.hiddenSize,
            eps: args.rmsNormEps
        )
        self._postAttentionLayerNorm.wrappedValue = RMSNorm(
            dimensions: args.hiddenSize,
            eps: args.rmsNormEps
        )
    }

    var isSliding: Bool { attention.isSliding }

    func callAsFunction(
        _ x: MLXArray,
        mask: MLXFast.ScaledDotProductAttentionMaskMode,
        cache: KVCache?
    ) -> MLXArray {
        let attentionOutput = attention(inputLayerNorm(x), mask: mask, cache: cache)
        let hiddenStates = x + attentionOutput
        return hiddenStates + mlp(postAttentionLayerNorm(hiddenStates))
    }
}

fileprivate final class Spark2_5ModelInner: Module {
    @ModuleInfo(key: "embedding") var embedding: Embedding
    let layers: [Spark2_5TransformerBlock]
    @ModuleInfo(key: "norm") var norm: RMSNorm

    init(_ args: Spark2_5Configuration) {
        self._embedding.wrappedValue = Embedding(
            embeddingCount: args.vocabularySize,
            dimensions: args.hiddenSize
        )
        self.layers = (0 ..< args.hiddenLayers).map { index in
            Spark2_5TransformerBlock(args, layerIndex: index)
        }
        self._norm.wrappedValue = RMSNorm(
            dimensions: args.hiddenSize,
            eps: args.rmsNormEps
        )
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        let hiddenStates = embedding(inputs)

        let firstFull = layers.firstIndex(where: { !$0.isSliding })
        let firstSliding = layers.firstIndex(where: { $0.isSliding })
        let fullMask = firstFull.map { index in
            createAttentionMask(h: hiddenStates, cache: cache?[index])
        } ?? .none
        let slidingMask = firstSliding.map { index in
            createAttentionMask(
                h: hiddenStates,
                cache: cache?[index],
                windowSize: 512
            )
        } ?? .none

        let output = layers.enumerated().reduce(hiddenStates) { hidden, entry in
            let (index, layer) = entry
            let mask = layer.isSliding ? slidingMask : fullMask
            return layer(hidden, mask: mask, cache: cache?[index])
        }
        return norm(output)
    }
}

final class Spark2_5Model: Module, LLMModel {
    let vocabularySize: Int
    let kvHeads: [Int]
    fileprivate let model: Spark2_5ModelInner
    private let configuration: Spark2_5Configuration

    @ModuleInfo(key: "lm_head") var lmHead: Linear?

    init(_ configuration: Spark2_5Configuration) {
        self.configuration = configuration
        self.vocabularySize = configuration.vocabularySize
        self.kvHeads = (0 ..< configuration.hiddenLayers).map { _ in configuration.kvHeads }
        self.model = Spark2_5ModelInner(configuration)

        if !configuration.tieWordEmbeddings {
            self._lmHead.wrappedValue = Linear(
                configuration.hiddenSize,
                configuration.vocabularySize,
                bias: false
            )
        }
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        let hiddenStates = model(inputs, cache: cache)
        if let lmHead {
            return lmHead(hiddenStates)
        }
        return model.embedding.asLinear(hiddenStates)
    }

    func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        var weights = weights
        if configuration.tieWordEmbeddings {
            weights["lm_head.weight"] = nil
        }
        return weights
    }

    var loraLayers: [Module] {
        model.layers
    }

    func newCache(parameters: GenerateParameters?) -> [KVCache] {
        model.layers.map { layer in
            if layer.isSliding {
                return RotatingKVCache(maxSize: configuration.slidingWindow, keep: 0)
            }
            return KVCacheSimple()
        }
    }
}

enum Spark2_5ModelFactory {
    static let shared: LLMModelFactory = {
        let typeRegistry = ModelTypeRegistry<LanguageModel>(creators: [
            "spark2_5": { data in
                let configuration = try JSONDecoder.json5().decode(
                    Spark2_5Configuration.self,
                    from: data
                )
                return Spark2_5Model(configuration)
            }
        ])
        return LLMModelFactory(
            typeRegistry: typeRegistry,
            modelRegistry: AbstractModelRegistry()
        )
    }()
}
