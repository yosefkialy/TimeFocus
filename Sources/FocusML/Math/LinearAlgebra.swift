import Accelerate
import Foundation

/// Small dense linear-algebra helpers on row-major `[Float]` buffers, backed by Accelerate.
public enum LA {
    /// C[m×n] = alpha · op(A) · op(B) + beta · C, all row-major.
    /// op(A) is m×k (A stored k×m when transA), op(B) is k×n (B stored n×k when transB).
    @inline(__always)
    public static func gemm(_ A: UnsafePointer<Float>, _ B: UnsafePointer<Float>, _ C: UnsafeMutablePointer<Float>,
                            m: Int, n: Int, k: Int, transA: Bool = false, transB: Bool = false,
                            alpha: Float = 1, beta: Float = 0) {
        let lda = transA ? m : k
        let ldb = transB ? k : n
        cblas_sgemm(CblasRowMajor, transA ? CblasTrans : CblasNoTrans, transB ? CblasTrans : CblasNoTrans,
                    Int32(m), Int32(n), Int32(k), alpha, A, Int32(lda), B, Int32(ldb), beta, C, Int32(n))
    }

    /// Array convenience wrapper for `gemm`.
    public static func matmul(_ A: [Float], _ B: [Float], m: Int, n: Int, k: Int,
                              transA: Bool = false, transB: Bool = false) -> [Float] {
        var C = [Float](repeating: 0, count: m * n)
        A.withUnsafeBufferPointer { a in
            B.withUnsafeBufferPointer { b in
                C.withUnsafeMutableBufferPointer { c in
                    gemm(a.baseAddress!, b.baseAddress!, c.baseAddress!, m: m, n: n, k: k, transA: transA, transB: transB)
                }
            }
        }
        return C
    }

    @inline(__always)
    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "dot: dimension mismatch \(a.count) vs \(b.count)")
        var r: Float = 0
        vDSP_dotpr(a, 1, b, 1, &r, vDSP_Length(a.count))
        return r
    }

    @inline(__always)
    public static func dot(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, _ n: Int) -> Float {
        var r: Float = 0
        vDSP_dotpr(a, 1, b, 1, &r, vDSP_Length(n))
        return r
    }

    public static func norm(_ a: [Float]) -> Float {
        var r: Float = 0
        vDSP_svesq(a, 1, &r, vDSP_Length(a.count))
        return r.squareRoot()
    }

    public static func normalize(_ a: inout [Float]) {
        let n = norm(a)
        guard n > 1e-12 else { return }
        var s = 1 / n
        vDSP_vsmul(a, 1, &s, &a, 1, vDSP_Length(a.count))
    }

    public static func normalized(_ a: [Float]) -> [Float] {
        var c = a
        normalize(&c)
        return c
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let na = norm(a), nb = norm(b)
        guard na > 1e-12, nb > 1e-12 else { return 0 }
        return dot(a, b) / (na * nb)
    }

    /// a += s · b
    public static func axpy(_ a: inout [Float], _ b: [Float], _ s: Float = 1) {
        precondition(a.count == b.count)
        var s = s
        vDSP_vsma(b, 1, &s, a, 1, &a, 1, vDSP_Length(a.count))
    }

    public static func scale(_ a: inout [Float], _ s: Float) {
        var s = s
        vDSP_vsmul(a, 1, &s, &a, 1, vDSP_Length(a.count))
    }

    /// Weighted mean of equal-length vectors.
    public static func mean(_ vectors: [[Float]], weights: [Float]? = nil) -> [Float] {
        guard let first = vectors.first else { return [] }
        var acc = [Float](repeating: 0, count: first.count)
        var total: Float = 0
        for (i, v) in vectors.enumerated() {
            let w = weights?[i] ?? 1
            axpy(&acc, v, w)
            total += w
        }
        if total > 0 { scale(&acc, 1 / total) }
        return acc
    }

    /// Numerically stable in-place softmax.
    public static func softmax(_ x: inout [Float]) {
        guard !x.isEmpty else { return }
        var mx: Float = 0
        vDSP_maxv(x, 1, &mx, vDSP_Length(x.count))
        var neg = -mx
        vDSP_vsadd(x, 1, &neg, &x, 1, vDSP_Length(x.count))
        var n = Int32(x.count)
        vvexpf(&x, x, &n)
        var sum: Float = 0
        vDSP_sve(x, 1, &sum, vDSP_Length(x.count))
        if sum > 0 { var inv = 1 / sum; vDSP_vsmul(x, 1, &inv, &x, 1, vDSP_Length(x.count)) }
    }

    public static func softmaxed(_ x: [Float], temperature: Float = 1) -> [Float] {
        var y = x
        if temperature != 1 { scale(&y, 1 / max(temperature, 1e-6)) }
        softmax(&y)
        return y
    }

    /// Row-wise softmax of an m×n row-major matrix.
    public static func softmaxRows(_ x: inout [Float], rows m: Int, cols n: Int) {
        x.withUnsafeMutableBufferPointer { buf in
            for r in 0..<m {
                let p = buf.baseAddress! + r * n
                var mx: Float = 0
                vDSP_maxv(p, 1, &mx, vDSP_Length(n))
                var neg = -mx
                vDSP_vsadd(p, 1, &neg, p, 1, vDSP_Length(n))
                var cnt = Int32(n)
                vvexpf(p, p, &cnt)
                var sum: Float = 0
                vDSP_sve(p, 1, &sum, vDSP_Length(n))
                var inv = 1 / max(sum, 1e-30)
                vDSP_vsmul(p, 1, &inv, p, 1, vDSP_Length(n))
            }
        }
    }

    /// L2-normalise each row of an m×n matrix in place; returns the original norms.
    @discardableResult
    public static func normalizeRows(_ x: inout [Float], rows m: Int, cols n: Int) -> [Float] {
        var norms = [Float](repeating: 0, count: m)
        x.withUnsafeMutableBufferPointer { buf in
            for r in 0..<m {
                let p = buf.baseAddress! + r * n
                var ss: Float = 0
                vDSP_svesq(p, 1, &ss, vDSP_Length(n))
                let nr = ss.squareRoot()
                norms[r] = nr
                if nr > 1e-12 { var inv = 1 / nr; vDSP_vsmul(p, 1, &inv, p, 1, vDSP_Length(n)) }
            }
        }
        return norms
    }

    /// Flattens equal-length vectors into one row-major matrix.
    public static func flatten(_ rows: [[Float]]) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(rows.count * (rows.first?.count ?? 0))
        for r in rows { out.append(contentsOf: r) }
        return out
    }

    /// Cosine-similarity matrix (n×n) of L2-normalised rows.
    public static func gram(_ flat: [Float], rows n: Int, cols d: Int) -> [Float] {
        var G = [Float](repeating: 0, count: n * n)
        flat.withUnsafeBufferPointer { a in
            G.withUnsafeMutableBufferPointer { g in
                gemm(a.baseAddress!, a.baseAddress!, g.baseAddress!, m: n, n: n, k: d, transB: true)
            }
        }
        return G
    }
}

/// Deterministic, fast PRNG (SplitMix64) so training and clustering are reproducible.
public struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func uniform() -> Float { Float(next() >> 40) / Float(1 << 24) }

    /// Standard normal via Box–Muller.
    public mutating func gaussian() -> Float {
        let u1 = max(uniform(), 1e-7), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
