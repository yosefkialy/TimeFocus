import Darwin
import Foundation
import MachO
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device foundation model (Apple Intelligence). Zero download, managed by the OS.
///
/// FoundationModels is weak-linked: the SDK this app was compiled with can differ from the OS it runs on (e.g. the SDK 26
/// beta on macOS 27, where `Guardrails` moved), and a weak symbol the OS doesn't export is bound to null — calling it
/// crashes. So before touching the API we check that every symbol this binary imports from FoundationModels exists in
/// the installed framework. The list is read from the binary's own import table, so it always matches the SDK the
/// binary was built with: rebuilding with a matching SDK is all it takes to turn Apple Intelligence on.
public final class AppleIntelligenceLLM: ChatLLM {
    public let id = "apple-intelligence"
    public let displayName = "Apple Intelligence (on-device)"

    public init() {}

    static let frameworkPath = "/System/Library/Frameworks/FoundationModels.framework/FoundationModels"
    private static let framework = dlopen(frameworkPath, RTLD_LAZY)

    /// Symbols this binary imports from FoundationModels (nil if its import table can't be read).
    public static let importedSymbols = MachOImports.symbols(importedFrom: "/System/Library/Frameworks/FoundationModels.framework/")

    /// Imported symbols the installed FoundationModels doesn't export (nil if the framework or the import table is unavailable).
    public static let missingSymbols: [String]? = {
        guard let framework, let symbols = importedSymbols else { return nil }
        return symbols.filter { dlsym(framework, $0) == nil }
    }()

    /// (available, human-readable reason)
    public static func availability() -> (Bool, String) {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return (false, "requires macOS 26 or later") }
        guard framework != nil else { return (false, "FoundationModels framework not present") }
        guard let imported = importedSymbols, !imported.isEmpty, let missing = missingSymbols else {
            return (false, "cannot read this build's FoundationModels imports")
        }
        guard missing.isEmpty else {
            return (false, "this build's SDK does not match the installed macOS (\(missing.count) of \(imported.count) API symbols missing) — rebuild with a matching SDK")
        }
        switch SystemLanguageModel.default.availability {
        case .available: return (true, "available")
        case .unavailable(let reason): return (false, "\(reason)")
        }
        #else
        return (false, "not compiled with FoundationModels")
        #endif
    }

    public func prepare() async throws {
        let (ok, reason) = Self.availability()
        guard ok else { throw LLMError.unavailable(reason) }
    }

    public func complete(system: String, user: String, maxTokens: Int, jsonMode: Bool) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), Self.availability().0 else { throw LLMError.unavailable("Apple Intelligence") }
        let session = LanguageModelSession(instructions: system)
        let response = try await session.respond(to: user, options: GenerationOptions(temperature: 0.2, maximumResponseTokens: maxTokens))
        return response.content
        #else
        throw LLMError.unavailable("not compiled with FoundationModels")
        #endif
    }

    public func shutdown() {}
}

/// Reads the dyld import table (LC_DYLD_CHAINED_FIXUPS) of the image this code is linked into.
enum MachOImports {
    // <mach-o/loader.h>
    private static let magic64: UInt32 = 0xFEED_FACF
    private static let segment64: UInt32 = 0x19
    private static let chainedFixups: UInt32 = 0x8000_0034
    /// LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LAZY_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB: each takes the next library ordinal.
    private static let dylibCommands: Set<UInt32> = [0xC, 0x8000_0018, 0x8000_001F, 0x20, 0x8000_0023]

    /// Names (without the leading underscore, as `dlsym` expects) of the symbols imported from the dylib whose install
    /// name starts with `prefix`; empty if that dylib isn't linked, nil if the import table can't be read.
    static func symbols(importedFrom prefix: String) -> [String]? {
        let image = #dsohandle
        let header = image.loadUnaligned(as: mach_header_64.self)
        guard header.magic == magic64 else { return nil }
        var text: segment_command_64?, linkedit: segment_command_64?, fixupsOffset: UInt32?
        var ordinal = 0, wanted: Int?
        var cmd = image + MemoryLayout<mach_header_64>.size
        for _ in 0..<header.ncmds {
            let lc = cmd.loadUnaligned(as: load_command.self)
            if lc.cmd == segment64 {
                let seg = cmd.loadUnaligned(as: segment_command_64.self)
                switch withUnsafeBytes(of: seg.segname, { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }) {
                case "__TEXT": text = seg
                case "__LINKEDIT": linkedit = seg
                default: break
                }
            } else if dylibCommands.contains(lc.cmd) {
                ordinal += 1
                let nameOffset = Int(cmd.loadUnaligned(as: dylib_command.self).dylib.name.offset)
                if String(cString: (cmd + nameOffset).assumingMemoryBound(to: CChar.self)).hasPrefix(prefix) { wanted = ordinal }
            } else if lc.cmd == chainedFixups {
                fixupsOffset = cmd.loadUnaligned(as: linkedit_data_command.self).dataoff
            }
            cmd += Int(lc.cmdsize)
        }
        guard let text, let linkedit, let fixupsOffset else { return nil }
        guard let wanted else { return [] }
        // The header is the start of __TEXT, so it gives the slide; __LINKEDIT is mapped at its vmaddr + slide.
        let slide = Int(bitPattern: image) - Int(text.vmaddr)
        guard let fixups = UnsafeRawPointer(bitPattern: slide + Int(linkedit.vmaddr) - Int(linkedit.fileoff) + Int(fixupsOffset)) else { return nil }

        // dyld_chained_fixups_header (<mach-o/fixup-chains.h>): fixups_version, starts_offset, imports_offset,
        // symbols_offset, imports_count, imports_format, symbols_format — all uint32.
        let field = { (i: Int) in Int(fixups.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)) }
        let (importsOffset, symbolsOffset, count, format) = (field(2), field(3), field(4), field(5))
        guard field(6) == 0 else { return nil } // zlib-compressed symbol names
        let stride: Int
        switch format {
        case 1: stride = 4 // DYLD_CHAINED_IMPORT
        case 2: stride = 8 // DYLD_CHAINED_IMPORT_ADDEND
        case 3: stride = 16 // DYLD_CHAINED_IMPORT_ADDEND64
        default: return nil
        }
        var names: [String] = []
        for i in 0..<count {
            let entry = fixups + importsOffset + i * stride
            let library: Int, nameOffset: Int
            if format == 3 { // lib_ordinal:16, weak_import:1, reserved:15, name_offset:32
                let raw = entry.loadUnaligned(as: UInt64.self)
                library = Int(raw & 0xFFFF)
                nameOffset = Int(raw >> 32)
            } else { // lib_ordinal:8, weak_import:1, name_offset:23
                let raw = entry.loadUnaligned(as: UInt32.self)
                library = Int(raw & 0xFF)
                nameOffset = Int(raw >> 9)
            }
            guard library == wanted else { continue }
            let name = String(cString: (fixups + symbolsOffset + nameOffset).assumingMemoryBound(to: CChar.self))
            names.append(name.hasPrefix("_") ? String(name.dropFirst()) : name)
        }
        return names
    }
}
