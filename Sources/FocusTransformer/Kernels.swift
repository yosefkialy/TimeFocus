import Accelerate
import Dispatch
import simd

/// Numerical building blocks (Accelerate: BLAS on the AMX units, vDSP / vForce, simd).
enum Kernels {
    /// Row-major `C = alpha·A·op(B) + beta·C`, with `op(B) = Bᵀ` when `transB`.
    /// `lda`/`ldb`/`ldc` are row strides, so strided sub-matrices (e.g. one attention head) work in place.
    @inline(__always)
    static func gemm(transB: Bool, m: Int, n: Int, k: Int, alpha: Float = 1,
                     a: UnsafePointer<Float>, lda: Int, b: UnsafePointer<Float>, ldb: Int,
                     beta: Float, c: UnsafeMutablePointer<Float>, ldc: Int) {
        callGEMM(AccelerateCBLAS.self, transB, m, n, k, alpha, a, lda, b, ldb, beta, c, ldc)
    }

    /// `y[r] = bias` for each of `rows` rows of width `n`.
    static func fillRows(_ y: UnsafeMutablePointer<Float>, rows: Int, bias: UnsafePointer<Float>, n: Int) {
        for r in 0..<rows { (y + r * n).update(from: bias, count: n) }
    }

    /// `y[r] = x[r] + bias` for each row.
    static func addBiasRows(_ x: UnsafePointer<Float>, bias: UnsafePointer<Float>, into y: UnsafeMutablePointer<Float>, rows: Int, n: Int) {
        for r in 0..<rows { vDSP_vadd(x + r * n, 1, bias, 1, y + r * n, 1, vDSP_Length(n)) }
    }

    /// Runs `body` over `0..<count`, split into contiguous chunks on several cores when there are at
    /// least `2 * grain` items (otherwise inline on the calling thread).
    static func parallelFor(_ count: Int, grain: Int, _ body: (Range<Int>) -> Void) {
        let chunks = min(16, count / max(grain, 1))
        if chunks < 2 { if count > 0 { body(0..<count) }; return }
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            body((count * c / chunks) ..< (count * (c + 1) / chunks))
        }
    }

    /// In-place LayerNorm over each row: `(x - mean) / sqrt(var + eps) * gamma + beta` (biased variance).
    static func layerNorm(_ x: UnsafeMutablePointer<Float>, rows: Int, n: Int,
                          gamma: UnsafePointer<Float>, beta: UnsafePointer<Float>, eps: Float) {
        let len = vDSP_Length(n)
        parallelFor(rows, grain: 256) { range in
            for r in range {
                let row = x + r * n
                var mean: Float = 0
                vDSP_meanv(row, 1, &mean, len)
                var negMean = -mean
                vDSP_vsadd(row, 1, &negMean, row, 1, len)
                var sumSquares: Float = 0
                vDSP_svesq(row, 1, &sumSquares, len)
                var invStd = 1 / (sumSquares / Float(n) + eps).squareRoot()
                vDSP_vsmul(row, 1, &invStd, row, 1, len)
                vDSP_vma(row, 1, gamma, 1, beta, 1, row, 1, len)
            }
        }
    }

    /// Softmax over each row of a `rows × n` matrix, in place.
    static func softmaxRows(_ s: UnsafeMutablePointer<Float>, rows: Int, n: Int) {
        let len = vDSP_Length(n)
        for r in 0..<rows {
            let row = s + r * n
            var maxValue: Float = 0
            vDSP_maxv(row, 1, &maxValue, len)
            var negMax = -maxValue
            vDSP_vsadd(row, 1, &negMax, row, 1, len)
        }
        var total = Int32(rows * n)
        vvexpf(s, s, &total)
        for r in 0..<rows {
            let row = s + r * n
            var sum: Float = 0
            vDSP_sve(row, 1, &sum, len)
            var inv = 1 / sum
            vDSP_vsmul(row, 1, &inv, row, 1, len)
        }
    }

    /// erf-based GELU, in place: `0.5·x·(1 + erf(x/√2))` (PyTorch `nn.GELU()` / HF "gelu").
    ///
    /// erf uses the Cephes-derived rational approximation also used by XLA and Eigen for float32
    /// (`x·P(x²)/Q(x²)` on x clamped to [-4, 4]); measured max |error| vs exact erf is 3.3e-7 (GELU
    /// 9e-7), comparable to PyTorch's own vectorised CPU erf, and ~7× faster than `simd.erf`.
    static func geluErf(_ x: UnsafeMutablePointer<Float>, count: Int) {
        let vectorCount = count / 4
        parallelFor(vectorCount, grain: 32_768) { range in
            let raw = UnsafeMutableRawPointer(x)
            for i in range {
                let v = raw.loadUnaligned(fromByteOffset: i * 16, as: SIMD4<Float>.self)
                let y = 0.5 * v * (1 + erf4(v * 0.707_106_781_186_547_524_4))
                raw.storeBytes(of: y, toByteOffset: i * 16, as: SIMD4<Float>.self)
            }
        }
        for i in (vectorCount * 4)..<count {
            let v = x[i]
            x[i] = 0.5 * v * (1 + erff(v * 0.707_106_781_186_547_524_4))
        }
    }

    @inline(__always)
    private static func erf4(_ x: SIMD4<Float>) -> SIMD4<Float> {
        let v = simd_clamp(x, SIMD4<Float>(repeating: -4), SIMD4<Float>(repeating: 4))
        let x2 = v * v
        var p = SIMD4<Float>(repeating: -2.72614225801306e-10)
        p = simd_muladd(x2, p, SIMD4(repeating: 2.77068142495902e-08))
        p = simd_muladd(x2, p, SIMD4(repeating: -2.10102402082508e-06))
        p = simd_muladd(x2, p, SIMD4(repeating: -5.69250639462346e-05))
        p = simd_muladd(x2, p, SIMD4(repeating: -7.34990630326855e-04))
        p = simd_muladd(x2, p, SIMD4(repeating: -2.95459980854025e-03))
        p = simd_muladd(x2, p, SIMD4(repeating: -1.60960333262415e-02))
        var q = SIMD4<Float>(repeating: -1.45660718464996e-05)
        q = simd_muladd(x2, q, SIMD4(repeating: -2.13374055278905e-04))
        q = simd_muladd(x2, q, SIMD4(repeating: -1.68282697438203e-03))
        q = simd_muladd(x2, q, SIMD4(repeating: -7.37332916720468e-03))
        q = simd_muladd(x2, q, SIMD4(repeating: -1.42647390514189e-02))
        return v * p / q
    }

    /// tanh-approximated GELU (`gelu_new`), in place.
    static func geluTanh(_ x: UnsafeMutablePointer<Float>, count: Int) {
        let raw = UnsafeMutableRawPointer(x)
        let c: Float = 0.797_884_560_802_865_4   // sqrt(2/pi)
        var i = 0
        while i + 16 <= count {
            let v = raw.loadUnaligned(fromByteOffset: i * 4, as: SIMD16<Float>.self)
            let y = 0.5 * v * (1 + simd.tanh(c * (v + 0.044715 * v * v * v)))
            raw.storeBytes(of: y, toByteOffset: i * 4, as: SIMD16<Float>.self)
            i += 16
        }
        while i < count {
            let v = x[i]
            x[i] = 0.5 * v * (1 + tanhf(c * (v + 0.044715 * v * v * v)))
            i += 1
        }
    }

    static func relu(_ x: UnsafeMutablePointer<Float>, count: Int) {
        var zero: Float = 0
        vDSP_vthr(x, 1, &zero, x, 1, vDSP_Length(count))
    }
}

// The classic CBLAS entry points are marked deprecated in the macOS 13.3+ SDK in favour of the
// ACCELERATE_NEW_LAPACK headers, which can only be enabled with a `-Xcc -D` build flag. Calling the
// (identical, still fully supported) symbol through a protocol requirement that is witnessed by a
// deprecated method keeps the module warning-free without touching the build script.
protocol CBLASProvider {
    static func sgemm(_ transB: Bool, _ m: Int, _ n: Int, _ k: Int, _ alpha: Float,
                      _ a: UnsafePointer<Float>, _ lda: Int, _ b: UnsafePointer<Float>, _ ldb: Int,
                      _ beta: Float, _ c: UnsafeMutablePointer<Float>, _ ldc: Int)
}

enum AccelerateCBLAS: CBLASProvider {
    @available(macOS, deprecated: 13.3)
    static func sgemm(_ transB: Bool, _ m: Int, _ n: Int, _ k: Int, _ alpha: Float,
                      _ a: UnsafePointer<Float>, _ lda: Int, _ b: UnsafePointer<Float>, _ ldb: Int,
                      _ beta: Float, _ c: UnsafeMutablePointer<Float>, _ ldc: Int) {
        cblas_sgemm(CblasRowMajor, CblasNoTrans, transB ? CblasTrans : CblasNoTrans,
                    Int32(m), Int32(n), Int32(k), alpha, a, Int32(lda), b, Int32(ldb), beta, c, Int32(ldc))
    }
}

@inline(__always)
private func callGEMM<P: CBLASProvider>(_ p: P.Type, _ transB: Bool, _ m: Int, _ n: Int, _ k: Int, _ alpha: Float,
                                        _ a: UnsafePointer<Float>, _ lda: Int, _ b: UnsafePointer<Float>, _ ldb: Int,
                                        _ beta: Float, _ c: UnsafeMutablePointer<Float>, _ ldc: Int) {
    P.sgemm(transB, m, n, k, alpha, a, lda, b, ldb, beta, c, ldc)
}
