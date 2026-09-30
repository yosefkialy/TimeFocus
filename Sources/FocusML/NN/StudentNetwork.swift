import Accelerate
import Foundation

/// Architecture of the real-time "student" network.
///
///   hashed sparse bag ──► EmbeddingBag(buckets × embDim, weighted mean) ─┐
///   dense behaviour features (standardised) ─────────────────────────────┴► concat
///     ► Linear(H1) ► ReLU ► Dropout ► Linear(H2) ► ReLU = z
///       ├► semantic head: Linear(semanticDim) ► L2-normalise   (distilled from the idle-time teacher encoder)
///       └► class head:    Linear(classCount)  ► softmax          (activity type)
///
/// It is small (~5 MB of weights at the default size) and runs in well under a millisecond, so it can classify
/// every tick without loading any large model. Heavy models only *teach* it while the Mac is idle.
public struct StudentConfig: Codable, Equatable {
    public var buckets: Int = 1 << 16
    public var embDim: Int = 64
    public var denseDim: Int = ActivityFeaturizer.denseDim
    public var hidden1: Int = 192
    public var hidden2: Int = 128
    public var semanticDim: Int = 0
    public var classCount: Int = 0
    public init() {}
    var inputDim: Int { embDim + denseDim }
}

public struct StudentTrainingOptions {
    public var epochs = 30
    public var batchSize = 64
    public var learningRate: Float = 2e-3
    public var embeddingLearningRate: Float = 1e-2
    public var weightDecay: Float = 1e-4
    public var dropout: Float = 0.1
    public var labelSmoothing: Float = 0.05
    public var semanticWeight: Float = 1.0
    /// Probability of dropping a whole feature field during training (teaches robustness to changed/missing text).
    public var fieldDropout: [FeatureField: Float] = [.text: 0.35, .title: 0.15, .titleGrams: 0.15, .path: 0.3, .host: 0.1, .app: 0.05]
    public var validationFraction: Float = 0.1
    public var seed: UInt64 = 42
    public init() {}
}

public struct StudentSample {
    public var x: FeaturizedActivity
    public var label: Int?
    public var weight: Float
    public var teacher: [Float]?
    public init(x: FeaturizedActivity, label: Int?, weight: Float, teacher: [Float]?) {
        self.x = x; self.label = label; self.weight = weight; self.teacher = teacher
    }
}

public struct StudentTrainingReport: Codable {
    public var epochs: Int
    public var trainLoss: Float
    public var validationAccuracy: Float?
    public var validationSemanticCosine: Float?
    public var samples: Int
    public var cancelled: Bool
    public var seconds: Double
}

public struct StudentPrediction {
    public var probabilities: [Float]
    public var semantic: [Float]?
}

public enum StudentNetworkError: Error { case badData(String) }

/// Adam state for one dense parameter tensor.
final class AdamTensor {
    var w: [Float]
    var m: [Float]
    var v: [Float]
    init(_ w: [Float]) { self.w = w; m = .init(repeating: 0, count: w.count); v = .init(repeating: 0, count: w.count) }

    func step(_ g: [Float], lr: Float, t: Int, weightDecay: Float, b1: Float = 0.9, b2: Float = 0.999, eps: Float = 1e-8) {
        let c1 = 1 - pow(b1, Float(t)), c2 = 1 - pow(b2, Float(t))
        let n = w.count
        w.withUnsafeMutableBufferPointer { w in
            m.withUnsafeMutableBufferPointer { m in
                v.withUnsafeMutableBufferPointer { v in
                    g.withUnsafeBufferPointer { g in
                        for i in 0..<n {
                            let gi = g[i]
                            m[i] = b1 * m[i] + (1 - b1) * gi
                            v[i] = b2 * v[i] + (1 - b2) * gi * gi
                            let upd = (m[i] / c1) / ((v[i] / c2).squareRoot() + eps)
                            w[i] -= lr * (upd + weightDecay * w[i])
                        }
                    }
                }
            }
        }
    }
}

public final class StudentNetwork {
    public private(set) var config: StudentConfig
    /// Activity-type (cluster) id for each output class index.
    public private(set) var classIDs: [Int64]
    public private(set) var denseMean: [Float]
    public private(set) var denseStd: [Float]
    public private(set) var lastReport: StudentTrainingReport?
    public private(set) var trainedAt: Date?

    // parameters (row-major; Linear weight is out × in)
    var E: [Float]
    var W1: [Float], b1: [Float]
    var W2: [Float], b2: [Float]
    var Ws: [Float], bs: [Float]
    var Wc: [Float], bc: [Float]

    public init(config: StudentConfig, classIDs: [Int64], seed: UInt64 = 7) {
        precondition(classIDs.count == config.classCount)
        self.config = config
        self.classIDs = classIDs
        var rng = SeededRandom(seed: seed)
        func gauss(_ n: Int, _ std: Float) -> [Float] { (0..<n).map { _ in rng.gaussian() * std } }
        let c = config
        E = gauss(c.buckets * c.embDim, 0.05)
        W1 = gauss(c.hidden1 * c.inputDim, (2 / Float(c.inputDim)).squareRoot()); b1 = .init(repeating: 0, count: c.hidden1)
        W2 = gauss(c.hidden2 * c.hidden1, (2 / Float(c.hidden1)).squareRoot()); b2 = .init(repeating: 0, count: c.hidden2)
        Ws = gauss(c.semanticDim * c.hidden2, (1 / Float(c.hidden2)).squareRoot()); bs = .init(repeating: 0, count: c.semanticDim)
        Wc = gauss(c.classCount * c.hidden2, (1 / Float(c.hidden2)).squareRoot()); bc = .init(repeating: 0, count: c.classCount)
        denseMean = .init(repeating: 0, count: c.denseDim)
        denseStd = .init(repeating: 1, count: c.denseDim)
    }

    public var parameterCount: Int { E.count + W1.count + b1.count + W2.count + b2.count + Ws.count + bs.count + Wc.count + bc.count }

    // MARK: - Forward

    private struct Cache {
        var n = 0
        var X: [Float] = []
        var A1: [Float] = [], Z1: [Float] = [], mask1: [Float] = []
        var A2: [Float] = [], Z2: [Float] = []
        var S: [Float] = [], Snorm: [Float] = []
        var P: [Float] = []
        var bagIdx: [[Int32]] = [], bagW: [[Float]] = []
    }

    /// Adds bias `b` to every row of the n×d matrix `M`.
    private static func addBias(_ M: inout [Float], _ b: [Float], rows n: Int) {
        let d = b.count
        M.withUnsafeMutableBufferPointer { m in
            b.withUnsafeBufferPointer { bb in
                for r in 0..<n { vDSP_vadd(m.baseAddress! + r * d, 1, bb.baseAddress!, 1, m.baseAddress! + r * d, 1, vDSP_Length(d)) }
            }
        }
    }

    private static func columnSums(_ M: [Float], rows n: Int, cols d: Int) -> [Float] {
        var out = [Float](repeating: 0, count: d)
        M.withUnsafeBufferPointer { m in
            out.withUnsafeMutableBufferPointer { o in
                for r in 0..<n { vDSP_vadd(o.baseAddress!, 1, m.baseAddress! + r * d, 1, o.baseAddress!, 1, vDSP_Length(d)) }
            }
        }
        return out
    }

    /// Number of leading dense features that describe behaviour (typing, clicking, scrolling, moving, media).
    public static let behaviorDims = 5

    private func forward(_ inputs: [(idx: [Int32], w: [Float], dense: [Float], bscale: Float)], dropout: Float, rng: inout SeededRandom) -> Cache {
        let c = config
        let n = inputs.count
        var cache = Cache()
        cache.n = n
        var X = [Float](repeating: 0, count: n * c.inputDim)
        cache.bagIdx.reserveCapacity(n); cache.bagW.reserveCapacity(n)
        E.withUnsafeBufferPointer { e in
            X.withUnsafeMutableBufferPointer { x in
                for (i, inp) in inputs.enumerated() {
                    let row = x.baseAddress! + i * c.inputDim
                    let total = inp.w.reduce(0, +)
                    var normW = inp.w
                    // bucket indices are reduced modulo the table size, so any featurizer size is safe
                    let rows = inp.idx.map { Int32(Int(UInt32(bitPattern: $0)) % c.buckets) }
                    if total > 1e-9 {
                        for j in 0..<normW.count { normW[j] /= total }
                        for (j, r) in rows.enumerated() {
                            var s = normW[j]
                            vDSP_vsma(e.baseAddress! + Int(r) * c.embDim, 1, &s, row, 1, row, 1, vDSP_Length(c.embDim))
                        }
                    }
                    for k in 0..<c.denseDim {
                        // standardised and clipped: an unusual value can shift, but never dominate, the input
                        var z = k < inp.dense.count ? (inp.dense[k] - denseMean[k]) / denseStd[k] : 0
                        // behaviour observed only briefly is shrunk towards the population mean (z → 0)
                        if k < Self.behaviorDims { z *= inp.bscale }
                        row[c.embDim + k] = z.isFinite ? max(-4, min(4, z)) : 0
                    }
                    cache.bagIdx.append(rows)
                    cache.bagW.append(normW)
                }
            }
        }
        cache.X = X
        var A1 = LA.matmul(X, W1, m: n, n: c.hidden1, k: c.inputDim, transB: true)
        Self.addBias(&A1, b1, rows: n)
        var Z1 = A1
        var mask = [Float](repeating: 1, count: Z1.count)
        let keepScale: Float = dropout > 0 ? 1 / (1 - dropout) : 1
        for i in 0..<Z1.count {
            if Z1[i] < 0 { Z1[i] = 0 }
            if dropout > 0 { mask[i] = rng.uniform() < dropout ? 0 : keepScale; Z1[i] *= mask[i] }
        }
        var A2 = LA.matmul(Z1, W2, m: n, n: c.hidden2, k: c.hidden1, transB: true)
        Self.addBias(&A2, b2, rows: n)
        var Z2 = A2
        for i in 0..<Z2.count where Z2[i] < 0 { Z2[i] = 0 }
        cache.A1 = A1; cache.Z1 = Z1; cache.mask1 = mask; cache.A2 = A2; cache.Z2 = Z2
        if c.semanticDim > 0 {
            var S = LA.matmul(Z2, Ws, m: n, n: c.semanticDim, k: c.hidden2, transB: true)
            Self.addBias(&S, bs, rows: n)
            cache.Snorm = LA.normalizeRows(&S, rows: n, cols: c.semanticDim)
            cache.S = S // normalised rows
        }
        if c.classCount > 0 {
            var L = LA.matmul(Z2, Wc, m: n, n: c.classCount, k: c.hidden2, transB: true)
            Self.addBias(&L, bc, rows: n)
            LA.softmaxRows(&L, rows: n, cols: c.classCount)
            cache.P = L
        }
        return cache
    }

    /// Real-time inference for one activity.
    /// - Parameter behaviorConfidence: 0…1, how much the behaviour statistics can be trusted
    ///   (e.g. seconds observed / 90). Unobserved behaviour is treated as average.
    public func predict(_ x: FeaturizedActivity, behaviorConfidence: Float = 1) -> StudentPrediction {
        var rng = SeededRandom(seed: 0)
        let cache = forward([(x.sparse.indices, x.sparse.values, x.dense, max(0, min(1, behaviorConfidence)))], dropout: 0, rng: &rng)
        let probs = config.classCount > 0 ? cache.P : []
        let sem = config.semanticDim > 0 ? Array(cache.S) : nil
        return StudentPrediction(probabilities: probs, semantic: sem)
    }

    /// Batched inference (used for evaluation and bulk re-scoring).
    public func predictBatch(_ xs: [FeaturizedActivity]) -> [StudentPrediction] {
        var out: [StudentPrediction] = []
        var rng = SeededRandom(seed: 0)
        let bs = 128
        var start = 0
        while start < xs.count {
            let chunk = Array(xs[start..<min(xs.count, start + bs)])
            let cache = forward(chunk.map { ($0.sparse.indices, $0.sparse.values, $0.dense, Float(1)) }, dropout: 0, rng: &rng)
            for i in 0..<chunk.count {
                let p = config.classCount > 0 ? Array(cache.P[(i * config.classCount)..<((i + 1) * config.classCount)]) : []
                let s = config.semanticDim > 0 ? Array(cache.S[(i * config.semanticDim)..<((i + 1) * config.semanticDim)]) : nil
                out.append(StudentPrediction(probabilities: p, semantic: s))
            }
            start += bs
        }
        return out
    }

    // MARK: - Training

    /// Trains the network from its current weights on `samples`. Labels are class indices into `classIDs`.
    /// `shouldCancel` is polled between mini-batches so training can stop the moment the user returns.
    @discardableResult
    public func train(_ samples: [StudentSample], options o: StudentTrainingOptions = .init(),
                      shouldCancel: () -> Bool = { false }) -> StudentTrainingReport {
        let t0 = Date()
        let c = config
        var rng = SeededRandom(seed: o.seed)

        // Dense feature standardisation from the training data.
        if !samples.isEmpty {
            var mean = [Float](repeating: 0, count: c.denseDim), sq = [Float](repeating: 0, count: c.denseDim)
            for s in samples { for k in 0..<c.denseDim { mean[k] += s.x.dense[k]; sq[k] += s.x.dense[k] * s.x.dense[k] } }
            let n = Float(samples.count)
            for k in 0..<c.denseDim {
                mean[k] /= n
                denseMean[k] = mean[k]
                let variance = max(0, (sq[k] / n) - mean[k] * mean[k])
                let std = variance.squareRoot()
                denseStd[k] = std.isFinite ? max(std, 0.05) : 1
            }
        }

        // Stratified-ish validation split.
        var order = Array(samples.indices)
        order.shuffle(using: &rng)
        let valCount = samples.count >= 60 ? Int(Float(samples.count) * o.validationFraction) : 0
        let valIdx = Array(order.prefix(valCount))
        let trainIdx = Array(order.dropFirst(valCount))

        let pW1 = AdamTensor(W1), pb1 = AdamTensor(b1), pW2 = AdamTensor(W2), pb2 = AdamTensor(b2)
        let pWs = AdamTensor(Ws), pbs = AdamTensor(bs), pWc = AdamTensor(Wc), pbc = AdamTensor(bc)
        var mE = [Float](repeating: 0, count: E.count), vE = [Float](repeating: 0, count: E.count)

        var step = 0
        var lastEpochLoss: Float = 0
        var cancelled = false
        let totalSteps = max(1, o.epochs * ((trainIdx.count + o.batchSize - 1) / max(o.batchSize, 1)))
        let K = c.classCount, D = c.semanticDim

        epochLoop: for _ in 0..<o.epochs {
            var shuffled = trainIdx
            shuffled.shuffle(using: &rng)
            var epochLoss: Float = 0, epochBatches = 0
            var b = 0
            while b < shuffled.count {
                if shouldCancel() { cancelled = true; break epochLoop }
                let batch = shuffled[b..<min(shuffled.count, b + o.batchSize)].map { samples[$0] }
                b += o.batchSize
                step += 1
                let progress = Float(step) / Float(totalSteps)
                let cosineDecay = 0.5 * (1 + cos(Float.pi * min(progress, 1)))
                let lr = o.learningRate * (0.1 + 0.9 * cosineDecay)
                let lrE = o.embeddingLearningRate * (0.1 + 0.9 * cosineDecay)

                // field dropout augmentation
                let inputs: [(idx: [Int32], w: [Float], dense: [Float], bscale: Float)] = batch.map { s in
                    // behaviour augmentation: sometimes unknown (0) or partially observed, as for brand-new windows
                    let r = rng.uniform()
                    let bscale: Float = r < 0.2 ? 0 : (r < 0.4 ? rng.uniform() : 1)
                    var dropped = Set<UInt8>()
                    for (field, p) in o.fieldDropout where rng.uniform() < p { dropped.insert(field.rawValue) }
                    if dropped.isEmpty { return (s.x.sparse.indices, s.x.sparse.values, s.x.dense, bscale) }
                    var idx: [Int32] = [], w: [Float] = []
                    for (j, f) in s.x.fields.enumerated() where !dropped.contains(f) {
                        idx.append(s.x.sparse.indices[j]); w.append(s.x.sparse.values[j])
                    }
                    if idx.isEmpty { return (s.x.sparse.indices, s.x.sparse.values, s.x.dense, bscale) }
                    return (idx, w, s.x.dense, bscale)
                }
                let cache = forward(inputs, dropout: o.dropout, rng: &rng)
                let n = batch.count
                var dZ2 = [Float](repeating: 0, count: n * c.hidden2)
                var loss: Float = 0

                // semantic (distillation) head: cosine loss against the teacher embedding
                var gWs = [Float](repeating: 0, count: Ws.count), gbs = [Float](repeating: 0, count: bs.count)
                if D > 0 {
                    let withTeacher = batch.enumerated().filter { $0.element.teacher?.count == D }
                    if !withTeacher.isEmpty {
                        let M = Float(withTeacher.count)
                        var dS = [Float](repeating: 0, count: n * D)
                        for (i, s) in withTeacher {
                            let t = s.teacher!
                            let base = i * D
                            var cosv: Float = 0
                            for k in 0..<D { cosv += cache.S[base + k] * t[k] }
                            loss += o.semanticWeight * (1 - cosv) / M
                            let nrm = max(cache.Snorm[i], 1e-6)
                            let scale = -o.semanticWeight / M
                            // d/dS of -(ŝ·t) = -(t - (ŝ·t) ŝ)/|S|
                            for k in 0..<D { dS[base + k] = scale * (t[k] - cosv * cache.S[base + k]) / nrm }
                        }
                        gWs = LA.matmul(dS, cache.Z2, m: D, n: c.hidden2, k: n, transA: true)
                        gbs = Self.columnSums(dS, rows: n, cols: D)
                        dS.withUnsafeBufferPointer { ds in Ws.withUnsafeBufferPointer { ws in dZ2.withUnsafeMutableBufferPointer { dz in
                            LA.gemm(ds.baseAddress!, ws.baseAddress!, dz.baseAddress!, m: n, n: c.hidden2, k: D, beta: 1)
                        } } }
                    }
                }

                // class head: weighted, label-smoothed cross-entropy
                var gWc = [Float](repeating: 0, count: Wc.count), gbc = [Float](repeating: 0, count: bc.count)
                if K > 0 {
                    let labeled = batch.enumerated().filter { $0.element.label != nil && $0.element.weight > 0 }
                    let wTot = labeled.reduce(Float(0)) { $0 + $1.element.weight }
                    if wTot > 0 {
                        var dL = [Float](repeating: 0, count: n * K)
                        let eps = o.labelSmoothing
                        for (i, s) in labeled {
                            let y = s.label!
                            let w = s.weight / wTot
                            for k in 0..<K {
                                let target = (k == y ? 1 - eps : 0) + eps / Float(K)
                                let p = max(cache.P[i * K + k], 1e-9)
                                loss -= w * target * log(p)
                                dL[i * K + k] = w * (cache.P[i * K + k] - target)
                            }
                        }
                        gWc = LA.matmul(dL, cache.Z2, m: K, n: c.hidden2, k: n, transA: true)
                        gbc = Self.columnSums(dL, rows: n, cols: K)
                        dL.withUnsafeBufferPointer { dl in Wc.withUnsafeBufferPointer { wc in dZ2.withUnsafeMutableBufferPointer { dz in
                            LA.gemm(dl.baseAddress!, wc.baseAddress!, dz.baseAddress!, m: n, n: c.hidden2, k: K, beta: 1)
                        } } }
                    }
                }

                // hidden layers
                var dA2 = dZ2
                for i in 0..<dA2.count where cache.A2[i] <= 0 { dA2[i] = 0 }
                let gW2 = LA.matmul(dA2, cache.Z1, m: c.hidden2, n: c.hidden1, k: n, transA: true)
                let gb2 = Self.columnSums(dA2, rows: n, cols: c.hidden2)
                var dA1 = LA.matmul(dA2, W2, m: n, n: c.hidden1, k: c.hidden2)
                for i in 0..<dA1.count { dA1[i] = cache.A1[i] > 0 ? dA1[i] * cache.mask1[i] : 0 }
                let gW1 = LA.matmul(dA1, cache.X, m: c.hidden1, n: c.inputDim, k: n, transA: true)
                let gb1 = Self.columnSums(dA1, rows: n, cols: c.hidden1)
                let dX = LA.matmul(dA1, W1, m: n, n: c.inputDim, k: c.hidden1)

                // sparse embedding gradient → lazy Adam on touched rows only
                var rowGrad: [Int32: [Float]] = [:]
                for i in 0..<n {
                    let dh = Array(dX[(i * c.inputDim)..<(i * c.inputDim + c.embDim)])
                    for (j, idx) in cache.bagIdx[i].enumerated() {
                        let w = cache.bagW[i][j]
                        if rowGrad[idx] == nil { rowGrad[idx] = [Float](repeating: 0, count: c.embDim) }
                        LA.axpy(&rowGrad[idx]!, dh, w)
                    }
                }
                let c1 = 1 - pow(Float(0.9), Float(step)), c2 = 1 - pow(Float(0.999), Float(step))
                for (idx, g) in rowGrad {
                    let base = Int(idx) * c.embDim
                    for k in 0..<c.embDim {
                        let p = base + k
                        mE[p] = 0.9 * mE[p] + 0.1 * g[k]
                        vE[p] = 0.999 * vE[p] + 0.001 * g[k] * g[k]
                        E[p] -= lrE * (mE[p] / c1) / ((vE[p] / c2).squareRoot() + 1e-8)
                    }
                }

                pW1.step(gW1, lr: lr, t: step, weightDecay: o.weightDecay); pb1.step(gb1, lr: lr, t: step, weightDecay: 0)
                pW2.step(gW2, lr: lr, t: step, weightDecay: o.weightDecay); pb2.step(gb2, lr: lr, t: step, weightDecay: 0)
                if D > 0 { pWs.step(gWs, lr: lr, t: step, weightDecay: o.weightDecay); pbs.step(gbs, lr: lr, t: step, weightDecay: 0) }
                if K > 0 { pWc.step(gWc, lr: lr, t: step, weightDecay: o.weightDecay); pbc.step(gbc, lr: lr, t: step, weightDecay: 0) }
                W1 = pW1.w; b1 = pb1.w; W2 = pW2.w; b2 = pb2.w; Ws = pWs.w; bs = pbs.w; Wc = pWc.w; bc = pbc.w

                epochLoss += loss
                epochBatches += 1
            }
            lastEpochLoss = epochBatches > 0 ? epochLoss / Float(epochBatches) : 0
        }

        // validation
        var valAcc: Float? = nil, valCos: Float? = nil
        if !valIdx.isEmpty {
            let preds = predictBatch(valIdx.map { samples[$0].x })
            var correct: Float = 0, wsum: Float = 0, cosSum: Float = 0, cosN: Float = 0
            for (j, i) in valIdx.enumerated() {
                let s = samples[i]
                if let y = s.label, K > 0 {
                    let p = preds[j].probabilities
                    let argmax = p.indices.max(by: { p[$0] < p[$1] }) ?? -1
                    if argmax == y { correct += s.weight }
                    wsum += s.weight
                }
                if let t = s.teacher, let sem = preds[j].semantic, t.count == sem.count {
                    cosSum += LA.dot(t, sem); cosN += 1
                }
            }
            if wsum > 0 { valAcc = correct / wsum }
            if cosN > 0 { valCos = cosSum / cosN }
        }
        let report = StudentTrainingReport(epochs: o.epochs, trainLoss: lastEpochLoss, validationAccuracy: valAcc,
                                           validationSemanticCosine: valCos, samples: samples.count,
                                           cancelled: cancelled, seconds: Date().timeIntervalSince(t0))
        lastReport = report
        trainedAt = Date()
        return report
    }

    // MARK: - Serialisation

    private struct Header: Codable {
        var version: Int
        var config: StudentConfig
        var classIDs: [Int64]
        var denseMean: [Float]
        var denseStd: [Float]
        var report: StudentTrainingReport?
        var trainedAt: Date?
    }

    private static let magic: [UInt8] = Array("TFST".utf8)

    public func serialized() -> Data {
        var data = Data(Self.magic)
        let header = Header(version: 1, config: config, classIDs: classIDs, denseMean: denseMean, denseStd: denseStd,
                            report: lastReport, trainedAt: trainedAt)
        let json = (try? JSONEncoder().encode(header)) ?? Data()
        var len = UInt32(json.count).littleEndian
        data.append(Data(bytes: &len, count: 4))
        data.append(json)
        for arr in [E, W1, b1, W2, b2, Ws, bs, Wc, bc] {
            arr.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        }
        return data
    }

    public convenience init(serialized data: Data) throws {
        guard data.count > 8, Array(data.prefix(4)) == Self.magic else { throw StudentNetworkError.badData("magic") }
        let len = data.subdata(in: 4..<8).withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard data.count >= 8 + len else { throw StudentNetworkError.badData("header") }
        let header = try JSONDecoder().decode(Header.self, from: data.subdata(in: 8..<(8 + len)))
        self.init(config: header.config, classIDs: header.classIDs, seed: 1)
        denseMean = header.denseMean
        denseStd = header.denseStd
        lastReport = header.report
        trainedAt = header.trainedAt
        var offset = 8 + len
        func read(_ count: Int) throws -> [Float] {
            let bytes = count * MemoryLayout<Float>.size
            guard offset + bytes <= data.count else { throw StudentNetworkError.badData("truncated") }
            let arr = data.subdata(in: offset..<(offset + bytes)).withUnsafeBytes { raw in
                Array(raw.bindMemory(to: Float.self))
            }
            offset += bytes
            return arr
        }
        E = try read(E.count); W1 = try read(W1.count); b1 = try read(b1.count)
        W2 = try read(W2.count); b2 = try read(b2.count); Ws = try read(Ws.count); bs = try read(bs.count)
        Wc = try read(Wc.count); bc = try read(bc.count)
    }
}
