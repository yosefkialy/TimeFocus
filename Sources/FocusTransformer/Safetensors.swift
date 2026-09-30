import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Read-only access to a `.safetensors` checkpoint.
///
/// Layout: `u64 little-endian header size N` · `N bytes of JSON header` · raw tensor data.
/// The header maps tensor names to `{dtype, shape, data_offsets:[begin,end]}` (offsets relative to
/// the start of the data section).
///
/// The whole file is memory-mapped read-only. Sparse readers (the ~384 MB word-embedding matrix)
/// gather rows straight from the mapping, so only the pages that are actually touched become
/// resident. Dense weights are copied into owned buffers with `pread`, which goes through the
/// buffer cache without faulting the mapping in, so those bytes are not counted twice in RSS.
final class SafetensorsFile {
    enum DType: String {
        case f64 = "F64", f32 = "F32", f16 = "F16", bf16 = "BF16"
        case i64 = "I64", i32 = "I32", i16 = "I16", i8 = "I8"
        case u64 = "U64", u32 = "U32", u16 = "U16", u8 = "U8", bool = "BOOL"
        case f8e4m3 = "F8_E4M3", f8e5m2 = "F8_E5M2"

        var byteSize: Int {
            switch self {
            case .f64, .i64, .u64: return 8
            case .f32, .i32, .u32: return 4
            case .f16, .bf16, .i16, .u16: return 2
            case .i8, .u8, .bool, .f8e4m3, .f8e5m2: return 1
            }
        }

        /// Floating types this loader can convert to `Float`.
        var isConvertibleToFloat: Bool {
            switch self {
            case .f64, .f32, .f16, .bf16: return true
            default: return false
            }
        }
    }

    struct Tensor {
        let name: String
        let dtype: DType
        let shape: [Int]
        /// Absolute byte offset of the tensor data inside the file.
        let fileOffset: Int
        let byteCount: Int
        var elementCount: Int { shape.reduce(1, *) }
    }

    let url: URL
    let fileSize: Int
    let tensors: [String: Tensor]
    private let fd: Int32
    private let mapping: UnsafeRawPointer

    init(url: URL) throws {
        let name = url.lastPathComponent
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw EncoderError.missingFile(name) }
        var ok = false
        defer { if !ok { close(fd) } }

        var st = stat()
        guard fstat(fd, &st) == 0 else { throw EncoderError.badSafetensors("\(name): cannot stat file") }
        let size = Int(st.st_size)
        guard size >= 8 else { throw EncoderError.badSafetensors("\(name): file too small") }

        var headerLen: UInt64 = 0
        guard pread(fd, &headerLen, 8, 0) == 8 else { throw EncoderError.badSafetensors("\(name): cannot read header size") }
        headerLen = UInt64(littleEndian: headerLen)
        guard headerLen > 1, headerLen <= UInt64(size - 8), headerLen < 100_000_000 else {
            throw EncoderError.badSafetensors("\(name): implausible header size \(headerLen)")
        }
        var header = Data(count: Int(headerLen))
        let got = header.withUnsafeMutableBytes { SafetensorsFile.readFully(fd, $0.baseAddress!, Int(headerLen), offset: 8) }
        guard got else { throw EncoderError.badSafetensors("\(name): cannot read header") }
        guard let json = (try? JSONSerialization.jsonObject(with: header)) as? [String: Any] else {
            throw EncoderError.badSafetensors("\(name): header is not a JSON object")
        }

        let dataStart = 8 + Int(headerLen)
        var tensors: [String: Tensor] = [:]
        tensors.reserveCapacity(json.count)
        for (key, value) in json where key != "__metadata__" {
            guard let entry = value as? [String: Any],
                  let dtypeName = entry["dtype"] as? String,
                  let shapeAny = entry["shape"] as? [Any],
                  let offsetsAny = entry["data_offsets"] as? [Any], offsetsAny.count == 2 else {
                throw EncoderError.badSafetensors("\(name): malformed entry for '\(key)'")
            }
            guard let dtype = DType(rawValue: dtypeName) else {
                throw EncoderError.badSafetensors("\(name): unknown dtype \(dtypeName) for '\(key)'")
            }
            let shape = shapeAny.compactMap { ($0 as? NSNumber)?.intValue }
            let offsets = offsetsAny.compactMap { ($0 as? NSNumber)?.intValue }
            guard shape.count == shapeAny.count, shape.allSatisfy({ $0 >= 0 }), offsets.count == 2 else {
                throw EncoderError.badSafetensors("\(name): bad shape/offsets for '\(key)'")
            }
            let begin = offsets[0], end = offsets[1]
            let count = shape.reduce(1, *)
            guard begin >= 0, end >= begin, dataStart + end <= size, end - begin == count * dtype.byteSize else {
                throw EncoderError.badSafetensors("\(name): tensor '\(key)' has inconsistent offsets")
            }
            tensors[key] = Tensor(name: key, dtype: dtype, shape: shape, fileOffset: dataStart + begin, byteCount: end - begin)
        }

        guard let base = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), base != MAP_FAILED else {
            throw EncoderError.badSafetensors("\(name): mmap failed (errno \(errno))")
        }
        self.url = url
        self.fileSize = size
        self.tensors = tensors
        self.fd = fd
        self.mapping = UnsafeRawPointer(base)
        ok = true
    }

    deinit {
        munmap(UnsafeMutableRawPointer(mutating: mapping), fileSize)
        close(fd)
    }

    /// Looks a tensor up by exact name.
    func tensor(_ name: String) -> Tensor? { tensors[name] }

    /// Copies a floating-point tensor into a new owned buffer (converted to Float32).
    /// Uses `pread`, so the corresponding pages of the mapping are never faulted in.
    func readFloats(_ t: Tensor) throws -> FloatBuffer {
        guard t.dtype.isConvertibleToFloat else {
            throw EncoderError.unsupported("tensor '\(t.name)' has dtype \(t.dtype.rawValue)")
        }
        let n = t.elementCount
        let out = FloatBuffer(count: n)
        if t.dtype == .f32 {
            guard SafetensorsFile.readFully(fd, UnsafeMutableRawPointer(out.pointer), t.byteCount, offset: t.fileOffset) else {
                throw EncoderError.badSafetensors("cannot read tensor '\(t.name)'")
            }
            return out
        }
        let tmp = UnsafeMutableRawPointer.allocate(byteCount: max(t.byteCount, 1), alignment: 16)
        defer { tmp.deallocate() }
        guard SafetensorsFile.readFully(fd, tmp, t.byteCount, offset: t.fileOffset) else {
            throw EncoderError.badSafetensors("cannot read tensor '\(t.name)'")
        }
        SafetensorsFile.convert(UnsafeRawPointer(tmp), dtype: t.dtype, count: n, into: out.pointer)
        return out
    }

    /// Gathers `count` elements starting at element index `start` of a floating tensor directly
    /// from the memory mapping (used for embedding-row lookups).
    @inline(__always)
    func gather(_ t: Tensor, start: Int, count: Int, into dst: UnsafeMutablePointer<Float>) {
        let src = mapping + t.fileOffset + start * t.dtype.byteSize
        SafetensorsFile.convert(src, dtype: t.dtype, count: count, into: dst)
    }

    // MARK: - Helpers

    private static func readFully(_ fd: Int32, _ dst: UnsafeMutableRawPointer, _ count: Int, offset: Int) -> Bool {
        var done = 0
        while done < count {
            let r = pread(fd, dst + done, count - done, off_t(offset + done))
            if r < 0 { if errno == EINTR { continue }; return false }
            if r == 0 { return false }
            done += r
        }
        return true
    }

    /// Converts little-endian F32/F16/BF16/F64 data (any alignment) to Float32.
    static func convert(_ src: UnsafeRawPointer, dtype: DType, count: Int, into dst: UnsafeMutablePointer<Float>) {
        switch dtype {
        case .f32:
            memcpy(dst, src, count * 4)
        case .f16:
            for i in 0..<count { dst[i] = halfToFloat(src.loadUnaligned(fromByteOffset: 2 * i, as: UInt16.self)) }
        case .bf16:
            for i in 0..<count {
                dst[i] = Float(bitPattern: UInt32(src.loadUnaligned(fromByteOffset: 2 * i, as: UInt16.self)) << 16)
            }
        case .f64:
            for i in 0..<count { dst[i] = Float(src.loadUnaligned(fromByteOffset: 8 * i, as: Double.self)) }
        default:
            dst.update(repeating: 0, count: count)
        }
    }

    /// IEEE 754 binary16 → binary32 (handles subnormals, infinities and NaNs).
    @inline(__always)
    static func halfToFloat(_ h: UInt16) -> Float {
        let sign = UInt32(h & 0x8000) << 16
        let exponent = UInt32((h >> 10) & 0x1F)
        let mantissa = UInt32(h & 0x3FF)
        if exponent == 0 {
            if mantissa == 0 { return Float(bitPattern: sign) }
            let magnitude = Float(mantissa) * Float(bitPattern: 0x3380_0000) // mantissa * 2^-24
            return sign != 0 ? -magnitude : magnitude
        }
        if exponent == 31 { return Float(bitPattern: sign | 0x7F80_0000 | (mantissa << 13)) }
        return Float(bitPattern: sign | ((exponent + 112) << 23) | (mantissa << 13))
    }
}

/// Owned, 64-byte-aligned Float storage. Weights and activations live in these instead of
/// Swift arrays so hot loops can use raw pointers without copy-on-write or exclusivity checks.
///
/// Buffers of 1 MB or more come straight from anonymous `mmap` and are `munmap`ed on release: the
/// system allocator otherwise keeps freed large blocks cached, so the ~35 MB of activations of a
/// 16×128 batch would stay in the process footprint after the call.
final class FloatBuffer {
    let pointer: UnsafeMutablePointer<Float>
    let count: Int
    private let mappedBytes: Int

    private static let mmapThreshold = 1 << 20

    init(count: Int) {
        self.count = count
        let bytes = max(count, 1) * MemoryLayout<Float>.stride
        if bytes >= FloatBuffer.mmapThreshold,
           let p = mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0), p != MAP_FAILED {
            mappedBytes = bytes
            pointer = p.bindMemory(to: Float.self, capacity: max(count, 1))
        } else {
            mappedBytes = 0
            let raw = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 64)
            pointer = raw.bindMemory(to: Float.self, capacity: max(count, 1))
        }
    }

    convenience init(copying array: [Float]) {
        self.init(count: array.count)
        array.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { pointer.initialize(from: base, count: src.count) }
        }
    }

    var byteCount: Int { count * MemoryLayout<Float>.stride }

    deinit {
        if mappedBytes > 0 {
            munmap(UnsafeMutableRawPointer(pointer), mappedBytes)
        } else {
            UnsafeMutableRawPointer(pointer).deallocate()
        }
    }
}
