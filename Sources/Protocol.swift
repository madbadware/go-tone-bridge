import Foundation

let appVersion = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "unknown"
let bridgePortName = "JUNO-DS GO Bridge"
let dsModel: [UInt8] = [0, 0, 0x3A]
let dsIdentity: [UInt8] = [0xF0,0x7E,0x10,6,2,0x41,0x3A,2,2,0,0,3,0,0,0xF7]

func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
func address(_ bytes: [UInt8]) -> Int { bytes.reduce(0) { ($0 << 7) | Int($1) } }
func encoded(_ number: Int) -> [UInt8] { [21,14,7,0].map { UInt8((number >> $0) & 127) } }
func packet(_ model: [UInt8], _ device: UInt8, _ command: UInt8, _ addr: Int, _ data: [UInt8]) -> [UInt8] {
    let body = encoded(addr) + data
    return [0xF0,0x41,device] + model + [command] + body + [UInt8((128 - body.reduce(0) { ($0 + Int($1)) % 128 }) % 128),0xF7]
}
struct RolandPacket {
    let device: UInt8
    let command: UInt8
    let addr: Int
    let data: [UInt8]
}
struct BridgeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
func parse(_ bytes: [UInt8], model: [UInt8]) throws -> RolandPacket? {
    let header = 3 + model.count
    guard bytes.count >= header + 7, Array(bytes.prefix(2)) == [0xF0,0x41],
          Array(bytes[3..<header]) == model, bytes.last == 0xF7 else { return nil }
    guard bytes[2..<(bytes.count-1)].allSatisfy({ $0 < 128 }) else { throw BridgeError(message: "Invalid MIDI data") }
    let command = bytes[header]
    guard command == 0x11 || command == 0x12 else { throw BridgeError(message: "Unsupported Roland command") }
    guard bytes[(header+1)..<(bytes.count-1)].reduce(0, { $0 + Int($1) }) % 128 == 0 else { throw BridgeError(message: "Invalid Roland checksum") }
    let data = Array(bytes[(header+5)..<(bytes.count-2)])
    guard command == 0x11 ? (data.count == 4 && address(data) > 0) : !data.isEmpty else {
        throw BridgeError(message: "Invalid read or write length")
    }
    return RolandPacket(device: bytes[2], command: command, addr: address(Array(bytes[(header+1)..<(header+5)])), data: data)
}

final class MIDIFramer {
    private var buffer: [UInt8] = []
    private var running: UInt8?
    private var needed = 0
    func feed(_ data: [UInt8]) throws -> [[UInt8]] {
        var result: [[UInt8]] = []
        for byte in data {
            if byte >= 0xF8 { result.append([byte]); continue }
            if buffer.first == 0xF0 {
                if byte == 0xF7 { buffer.append(byte); result.append(buffer); buffer.removeAll(); continue }
                if byte < 128 {
                    buffer.append(byte)
                    guard buffer.count <= 1_048_576 else { throw BridgeError(message: "Unterminated MIDI message") }
                    continue
                }
                buffer.removeAll()
            }
            if byte >= 128 {
                buffer.removeAll()
                if byte == 0xF0 { running = nil; buffer.append(byte); continue }
                running = byte < 0xF0 ? byte : nil
                needed = byte < 0xF0 ? ([0xC0,0xD0].contains(byte & 0xF0) ? 1 : 2) : [0xF1:1,0xF2:2,0xF3:1][Int(byte), default:0]
                if needed == 0 { result.append([byte]) } else { buffer.append(byte) }
            } else {
                if buffer.isEmpty {
                    guard let status = running else { continue }
                    buffer.append(status); needed = [0xC0,0xD0].contains(status & 0xF0) ? 1 : 2
                }
                buffer.append(byte)
                if buffer.count == needed + 1 { result.append(buffer); buffer.removeAll() }
            }
        }
        return result
    }
}

struct Translation {
    let bytes: [UInt8]?
    let action: String
    var consumed = false
}
struct Translator {
    let model: [UInt8]
    let device: UInt8
    let writesAllowed: Bool
    func translate(_ bytes: [UInt8], toKeyboard: Bool) throws -> Translation {
        if toKeyboard, bytes.count == 6, Array(bytes.prefix(2)) == [0xF0,0x7E],
           [0x10,0x7F].contains(bytes[2]), Array(bytes.suffix(3)) == [6,1,0xF7] {
            return Translation(bytes: [0xF0,0x7E,device,6,1,0xF7], action: "Identity inquiry")
        }
        if !toKeyboard, bytes.count == 15, Array(bytes.prefix(2)) == [0xF0,0x7E], bytes[2] == device,
           Array(bytes[3..<8]) == [6,2,0x41,model.last!,3], bytes.last == 0xF7 {
            return Translation(bytes: dsIdentity, action: "JUNO-DS identity supplied")
        }
        guard bytes.first == 0xF0 else {
            if toKeyboard && (!writesAllowed || bytes.first == 0xFF) {
                return Translation(bytes: nil, action: writesAllowed ? "System reset blocked" : "Writes are off")
            }
            return Translation(bytes: bytes, action: "Ordinary MIDI")
        }
        guard let p = try parse(bytes, model: toKeyboard ? dsModel : model) else {
            return Translation(bytes: nil, action: "Unrecognized SysEx blocked")
        }
        guard toKeyboard ? [0x10,0x7F].contains(p.device) : p.device == device else {
            return Translation(bytes: nil, action: "Unexpected device ID blocked")
        }
        if toKeyboard && p.command == 0x12 {
            let end = p.addr + p.data.count
            // JUNO-DS manual: temporary performance/16 parts, two Patch-mode parts.
            let temporary = ((0x10 << 21)..<(0x15 << 21)).contains(p.addr) && end <= 0x15 << 21
            let patchMode = p.addr >= 0x1F << 21 && end <= address([0x1F,0x40,0,0])
            // Only the exact live Patch/Performance mode switch, never whole Setup.
            let modeSwitch = p.addr == 0x01 << 21 && (p.data == [0] || p.data == [1])
            // Manual Setup bank/program selectors used before Librarian audition.
            let soundSelection = [1,4,7].contains(p.addr - (0x01 << 21)) && p.data.count == 3
            // Tone Manager's Preview start/stop commands, from its local code.
            let preview = p.addr == address([0x0F,0,0x20,0]) && (p.data == [0] || p.data == [1])
            let live = temporary || patchMode || modeSwitch || soundSelection || preview
            // All 128 performances, 256 patches and 8 drum kits. No slot filter.
            let stored = [(0x20 << 21,0x21 << 21),(0x30 << 21,0x32 << 21),(0x40 << 21,0x41 << 21)]
                .contains { p.addr >= $0.0 && end <= $0.1 }
            if p.addr == address([0x0F,0,0x10,1]) && p.data == [1] {
                // Handle the JUNO-DS completion command after direct memory writes.
                return Translation(bytes:nil, action:writesAllowed ? "Librarian completion handled; GO writes are direct" : "Writes are off", consumed:writesAllowed)
            }
            guard writesAllowed && (live || stored) else {
                return Translation(bytes:nil, action:(live || stored) ? "Writes are off" : "Unsupported write address blocked")
            }
        }
        return Translation(bytes: packet(toKeyboard ? model : dsModel, toKeyboard ? device : 0x10, p.command, p.addr, p.data), action: "Model and device ID translated")
    }
}

struct WaveNames: Decodable {
    let banks: [String:[String]]
}
struct FactoryPerformances: Decodable {
    struct Record: Decodable { let msb: UInt8; let lsb: UInt8; let program: UInt8; let name: String }
    let records: [Record]
}
struct PresetPatches: Decodable {
    struct Record: Decodable {
        let msb: UInt8; let lsb: UInt8; let program: UInt8; let category: UInt8; let group: UInt8; let name: String
    }
    let models: [String:[Record]]
}
struct MetadataReply { let messages: [[UInt8]]; let action: String }
struct NameCatalogue {
    let replyAddress: Int
    let count: Int
    let size: Int
    let base: Int
    let kind: String
    var slot = 0
    var attempts = 0
    var lastRequest: TimeInterval = 0
    init?(_ p: RolandPacket) {
        guard p.command == 0x11, p.data.count == 4 else { return nil }
        switch encoded(p.addr) {
        case [15,0,2,1] where p.data[1] == 0: count = 128; size = 12; base = 0x20 << 21; kind = "user performances"
        case [15,0,3,1]: count = 256; size = 13; base = 0x30 << 21; kind = "user patches"
        case [15,0,4,1]: count = 8; size = 12; base = 0x40 << 21; kind = "user drum kits"
        default: return nil
        }
        replyAddress = p.addr
    }
    var readAddress: Int { base + (slot << (kind == "user drum kits" ? 18 : 14)) }
    func record(_ nameData: [UInt8]) -> [UInt8] {
        if size == 13 { return [87,UInt8(slot / 128),UInt8(slot % 128),nameData[12],0]+Array(nameData.prefix(12)) }
        if kind == "user drum kits" { return [86,0,UInt8(slot),0,0]+Array(nameData.prefix(12)) }
        return [85,0,UInt8(slot)]+Array(nameData.prefix(12))
    }
}
final class ToneMetadata {
    let waves: WaveNames
    let performances: FactoryPerformances
    let patches: PresetPatches
    var keyboardModel = "GO:KEYS"
    struct Catalogue { var last: TimeInterval; var records = 0 }
    var catalogues: [Int:Catalogue] = [:]
    init(url: URL) throws {
        waves = try JSONDecoder().decode(WaveNames.self, from: Data(contentsOf: url))
        performances = try JSONDecoder().decode(FactoryPerformances.self, from:Data(contentsOf:url.deletingLastPathComponent().appendingPathComponent("factory-performances.json")))
        patches = try JSONDecoder().decode(PresetPatches.self, from:Data(contentsOf:url.deletingLastPathComponent().appendingPathComponent("preset-patches.json")))
    }
    func reply(_ addr: Int, _ data: [UInt8]) -> [UInt8] { packet(dsModel, 0x10, 0x12, addr, data) }
    func request(_ p: RolandPacket, time: TimeInterval) -> MetadataReply? {
        let a = encoded(p.addr)
        if p.command == 0x12 && a == [15,0,127,0] && (p.data == [0] || p.data == [1]) {
            return MetadataReply(messages: [], action: "PC-mode housekeeping handled by bridge")
        }
        guard p.command == 0x11 else { return nil }
        switch a {
        case [15,0,3,49] where p.data.count == 4:
            let messages = (patches.models[keyboardModel] ?? []).filter { $0.group == p.data[0] }.map { record -> [UInt8] in
                var name = Array(record.name.utf8.prefix(12)); name += Array(repeating:32,count:12-name.count)
                return reply(p.addr,[record.msb,record.lsb,record.program,record.category,0]+name)
            } + [reply(p.addr,Array(repeating:0,count:17))]
            return MetadataReply(messages:messages,action:"Bundled \(keyboardModel) patch/drum catalogue")
        case [15,0,2,1] where p.data.count == 4 && p.data[1] == 64:
            let messages = performances.records.map { record -> [UInt8] in
                var name = Array(record.name.utf8.prefix(12)); name += Array(repeating:32,count:12-name.count)
                return reply(p.addr,[record.msb,record.lsb,record.program]+name)
            } + [reply(p.addr,Array(repeating:0,count:17))]
            return MetadataReply(messages:messages,action:"Bundled factory performance catalogue")
        case [15,0,0,4] where p.data == [0,0,0,1]:
            return MetadataReply(messages: [reply(p.addr,[1])], action: "Bridge profile cache-version 01; not keyboard firmware")
        case [15,0,0,0] where p.data == [0,0,0,1]:
            return MetadataReply(messages: [reply(p.addr,[0,0]+Array(repeating:32,count:5))], action: "No-expansion placeholder")
        case [15,0,1,1], [15,0,1,3]:
            guard p.data == [0,0,0,1] else { return nil }
            var messages: [[UInt8]] = []
            for (index,name) in (waves.banks[a.last == 1 ? "1" : "2"] ?? []).enumerated() {
                let n = index + 1
                let number = [12,8,4,0].map { UInt8((n >> $0) & 15) }
                var text = Array(name.utf8.prefix(12)); text += Array(repeating:32,count:12-text.count)
                messages.append(reply(p.addr,number+text))
            }
            messages.append(reply(p.addr,Array(repeating:0,count:16)))
            return MetadataReply(messages: messages, action: "Bundled wave-name catalogue")
        case [15,0,1,17]: return MetadataReply(messages: [reply(p.addr,Array(repeating:0,count:16))], action: "Empty expansion catalogue")
        case [15,0,7,1]: return MetadataReply(messages: [reply(p.addr,[0,0,0]+Array(repeating:32,count:12)+Array(repeating:0,count:7)), reply(p.addr,Array(repeating:0,count:22))], action: "Sample features unavailable")
        case [15,0,6,1]: return MetadataReply(messages: [reply(p.addr,Array(repeating:0,count:7))], action: "Multisample features unavailable")
        case [15,0,15,0], [15,0,15,1]: return MetadataReply(messages: [reply(p.addr,Array(repeating:0,count:8))], action: "Sample-memory placeholder")
        case [15,0,2,1], [15,0,3,1], [15,0,3,49], [15,0,4,1]:
            catalogues[p.addr] = Catalogue(last:time)
        default: break
        }
        return nil
    }
    func observe(_ p: RolandPacket, time: TimeInterval) {
        guard var c = catalogues[p.addr] else { return }
        if p.data.count >= 10 && p.data.prefix(10).allSatisfy({$0 == 0}) { catalogues.removeValue(forKey:p.addr) }
        else { c.last = time; c.records += 1; catalogues[p.addr] = c }
    }
    func tick(time: TimeInterval) -> [MetadataReply] {
        var replies: [MetadataReply] = []
        for (addr,c) in catalogues where time - c.last >= 2 {
            replies.append(MetadataReply(messages:[reply(addr,Array(repeating:0,count:17))], action:"Catalogue stopped after \(c.records) records; list may be incomplete"))
            catalogues.removeValue(forKey:addr)
        }
        return replies
    }
}
