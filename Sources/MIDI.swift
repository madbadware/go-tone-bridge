import Foundation
import CoreMIDI
import Darwin

struct MIDIPort: Identifiable, Hashable {
    let id: MIDIEndpointRef
    let name: String
}
func midiPorts(sources: Bool, includeBridge: Bool = false) -> [MIDIPort] {
    let count = sources ? MIDIGetNumberOfSources() : MIDIGetNumberOfDestinations()
    return (0..<count).compactMap { index in
        let endpoint = sources ? MIDIGetSource(index) : MIDIGetDestination(index)
        var label: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(endpoint,kMIDIPropertyDisplayName,&label) == noErr, let label else { return nil }
        let name = label.takeRetainedValue() as String
        return name == bridgePortName && !includeBridge ? nil : MIDIPort(id:endpoint,name:name)
    }
}

final class Capture {
    let url: URL
    private let file: FileHandle
    init(at requested: URL) throws {
        try FileManager.default.createDirectory(at:requested.deletingLastPathComponent(),withIntermediateDirectories:true)
        var candidate = requested, suffix = 0
        while true {
            let fd = Darwin.open(candidate.path,O_WRONLY | O_CREAT | O_EXCL,0o600)
            if fd >= 0 { url = candidate; file = FileHandle(fileDescriptor:fd,closeOnDealloc:true); break }
            guard errno == EEXIST else { throw BridgeError(message:"Could not create capture: \(String(cString:strerror(errno)))") }
            suffix += 1
            candidate = requested.deletingLastPathComponent().appendingPathComponent(requested.deletingPathExtension().lastPathComponent+"-\(suffix).jsonl")
        }
    }
    func record(_ fields: [String:Any]) throws {
        var row = fields; row["time"] = ISO8601DateFormatter().string(from:Date())
        var data = try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]); data.append(10)
        try file.write(contentsOf:data)
    }
    func close() { try? file.close() }
}

struct BridgeSnapshot {
    var state = "Stopped"
    var detail = "Select MIDI ports and click Start."
    var ready = false
    var active = false
    var reads = 0
    var writes = 0
    var received = 0
    var supplied = 0
    var blocked = 0
    var warning = ""
    var activity = ""
    var logURL: URL?
}

// Both receive callbacks copy packet bytes before dispatching. CoreMIDI's packet
// storage expires when the callback returns. All framing/state/sending is serial.
private let hardwareCallback: MIDIReadProc = { packets,context,_ in
    guard let context else { return }
    Unmanaged<BridgeEngine>.fromOpaque(context).takeUnretainedValue().receive(packets,toKeyboard:false)
}
private let appCallback: MIDIReadProc = { packets,context,_ in
    guard let context else { return }
    Unmanaged<BridgeEngine>.fromOpaque(context).takeUnretainedValue().receive(packets,toKeyboard:true)
}

final class BridgeEngine {
    private let queue = DispatchQueue(label:"GO Tone Bridge MIDI")
    private var client: MIDIClientRef = 0
    private var input: MIDIPortRef = 0
    private var output: MIDIPortRef = 0
    private var virtualSource: MIDIEndpointRef = 0
    private var virtualDestination: MIDIEndpointRef = 0
    private var destination: MIDIEndpointRef = 0
    private var hardwareFramer = MIDIFramer(), appFramer = MIDIFramer()
    private var translator: Translator?
    private var metadata: ToneMetadata?
    private var capture: Capture?
    private var snapshot = BridgeSnapshot()
    private var generation = 0
    private var identityAttempts = 0
    private var nameJobs: [NameCatalogue] = []
    private var writesAllowed = false
    private var previewActive = false
    private var lastSend: TimeInterval = 0
    var onChange: ((BridgeSnapshot) -> Void)?
    private func publish() {
        let value = snapshot
        DispatchQueue.main.async { [weak self] in self?.onChange?(value) }
    }
    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw NSError(domain:"CoreMIDI",code:Int(status),userInfo:[NSLocalizedDescriptionKey:"MIDI connection failed (\(status)). Refresh devices and try again."]) }
    }
    private func log(_ fields: [String:Any]) throws { try capture?.record(fields) }
    func start(source: MIDIPort, destination: MIDIPort, writesAllowed: Bool, logURL: URL?, waveURL: URL) {
        queue.async { [self] in
            guard client == 0 else { return }
            generation += 1
            snapshot = BridgeSnapshot(); snapshot.state = "Connecting…"; snapshot.active = true
            snapshot.detail = "Checking the keyboard’s identity…"; self.writesAllowed = writesAllowed
            publish()
            do {
                guard !midiPorts(sources:true,includeBridge:true).contains(where:{$0.name == bridgePortName}) &&
                      !midiPorts(sources:false,includeBridge:true).contains(where:{$0.name == bridgePortName}) else {
                    throw BridgeError(message:"Bridge ports already exist. Stop the other bridge instance.")
                }
                metadata = try ToneMetadata(url:waveURL)
                if let logURL { capture = try Capture(at:logURL); snapshot.logURL = capture?.url }
                try log(["event":"session","version":appVersion,"input":source.name,"output":destination.name,"allow_writes":writesAllowed,"virtual_name":bridgePortName])
                self.destination = destination.id
                let context = Unmanaged.passUnretained(self).toOpaque()
                try check(MIDIClientCreate("GO Tone Bridge" as CFString,nil,nil,&client))
                try check(MIDIInputPortCreate(client,"Keyboard input" as CFString,hardwareCallback,context,&input))
                try check(MIDIOutputPortCreate(client,"Keyboard output" as CFString,&output))
                try check(MIDIPortConnectSource(input,source.id,nil))
                hardwareFramer = MIDIFramer(); appFramer = MIDIFramer(); identityAttempts = 0
                try inquireIdentity()
            } catch { fail(error) }
        }
    }
    private func inquireIdentity() throws {
        identityAttempts += 1
        try send([0xF0,0x7E,0x7F,6,1,0xF7],toKeyboard:true)
        let token = generation
        queue.asyncAfter(deadline:.now()+3) { [weak self] in
            guard let self, self.generation == token, self.client != 0, self.translator == nil else { return }
            do {
                guard self.identityAttempts < 3 else { throw BridgeError(message:"Keyboard identity request timed out. Check MIDI ports and retry Start.") }
                self.snapshot.detail = "Waiting for identity response (attempt \(self.identityAttempts+1) of 3)…"; self.publish()
                try self.inquireIdentity()
            } catch { self.fail(error) }
        }
    }
    func stop() { queue.async { [self] in dispose(); snapshot.state = "Stopped"; snapshot.detail = "Bridge MIDI ports closed."; publish() } }
    func shutdown() { queue.sync { dispose() } }
    private func dispose() {
        generation += 1
        if previewActive, let translator, client != 0 {
            try? send(packet(translator.model,translator.device,0x12,address([0x0F,0,0x20,0]),[0]),toKeyboard:true,origin:"bridge-preview-stop")
        }
        previewActive = false
        if client != 0 { MIDIClientDispose(client) }
        client = 0; input = 0; output = 0; virtualSource = 0; virtualDestination = 0
        translator = nil; metadata = nil
        nameJobs.removeAll()
        try? log(["event":"stopped"]); capture?.close(); capture = nil
        snapshot.active = false; snapshot.ready = false
        snapshot.activity = ""
    }
    private func fail(_ error: Error) {
        try? log(["event":"error","message":error.localizedDescription])
        dispose(); snapshot.state = "Connection stopped"; snapshot.detail = error.localizedDescription; publish()
    }
    func receive(_ packets: UnsafePointer<MIDIPacketList>, toKeyboard: Bool) {
        var payloads: [[UInt8]] = []
        let raw = UnsafeRawPointer(packets).advanced(by:MemoryLayout<MIDIPacketList>.offset(of:\.packet)!)
        var p = UnsafeMutableRawPointer(mutating:raw).assumingMemoryBound(to:MIDIPacket.self)
        for _ in 0..<packets.pointee.numPackets {
            let data = UnsafeRawPointer(p).advanced(by:MemoryLayout<MIDIPacket>.offset(of:\.data)!)
            payloads.append(Array(UnsafeBufferPointer(start:data.assumingMemoryBound(to:UInt8.self),count:Int(p.pointee.length))))
            p = MIDIPacketNext(p)
        }
        queue.async { [weak self] in
            guard let self, self.client != 0 else { return }
            do {
                for payload in payloads {
                    for message in try (toKeyboard ? self.appFramer : self.hardwareFramer).feed(payload) {
                        try self.process(message,toKeyboard:toKeyboard)
                    }
                }
            } catch { self.fail(error) }
        }
    }
    private func process(_ bytes: [UInt8], toKeyboard: Bool) throws {
        let direction = toKeyboard ? "app-to-go" : "go-to-app"
        guard let translator else {
            try log(["event":"identity-receive","direction":direction,"hex":hex(bytes)])
            guard !toKeyboard, bytes.count == 15, Array(bytes.prefix(2)) == [0xF0,0x7E],
                  Array(bytes[3..<6]) == [6,2,0x41], bytes.last == 0xF7 else { return }
            guard [0x3C,0x3D].contains(bytes[6]), bytes[7] == 3 else {
                throw BridgeError(message:"Unsupported keyboard identity. Supported models: original GO:KEYS and GO:PIANO.")
            }
            self.translator = Translator(model:[0,0,0,bytes[6]],device:bytes[2],writesAllowed:writesAllowed)
            metadata?.keyboardModel = bytes[6] == 0x3C ? "GO:KEYS" : "GO:PIANO"
            let context = Unmanaged.passUnretained(self).toOpaque()
            try check(MIDISourceCreate(client,bridgePortName as CFString,&virtualSource))
            try check(MIDIDestinationCreate(client,bridgePortName as CFString,appCallback,context,&virtualDestination))
            // Stable endpoint identities let Tone Manager reconnect after Stop/
            // Start. The duplicate-instance check prevents ambiguous endpoints.
            try check(MIDIObjectSetIntegerProperty(virtualSource,kMIDIPropertyUniqueID,0x474F4201))
            try check(MIDIObjectSetIntegerProperty(virtualDestination,kMIDIPropertyUniqueID,0x474F4202))
            try log(["event":"hardware-identity","hex":hex(bytes),"model":bytes[6] == 0x3C ? "GO:KEYS" : "GO:PIANO"])
            snapshot.ready = true; snapshot.state = "Ready · \(bytes[6] == 0x3C ? "GO:KEYS" : "GO:PIANO")"
            snapshot.detail = "Bridge ports: \(bridgePortName) · \(writesAllowed ? "Writes enabled" : "Read-only")"
            publish(); tick(token:generation)
            return
        }
        if !toKeyboard { snapshot.received += 1 }
        do {
            if let p = try parse(bytes,model:toKeyboard ? dsModel : translator.model) {
                if toKeyboard && [0x10,0x7F].contains(p.device), let job = NameCatalogue(p) {
                    try log(["event":"catalogue-request","direction":direction,"original_hex":hex(bytes),"kind":job.kind,"count":job.count])
                    // Never launch native bulk streams: those can interfere with
                    // ordinary reads. Use individual stored-name RQ1s.
                    if !nameJobs.contains(where:{$0.replyAddress == job.replyAddress}) {
                        nameJobs.append(job)
                        if nameJobs.count == 1 { try requestNextName() }
                    }
                    return
                }
                if !toKeyboard && p.device == translator.device && p.command == 0x12,
                   let job = nameJobs.first, p.addr == job.readAddress, p.data.count == job.size {
                    try log(["event":"catalogue-name-readback","direction":"go-to-bridge","original_hex":hex(bytes),"kind":job.kind,"slot":job.slot+1])
                    let result = packet(dsModel,0x10,0x12,job.replyAddress,job.record(p.data))
                    try send(result,toKeyboard:false,origin:"bridge-to-app")
                    try log(["event":"bridge-catalogue","direction":"bridge-to-app","hex":hex(result),"action":"Keyboard user-name response" ])
                    nameJobs[0].slot += 1; nameJobs[0].attempts = 0
                    if nameJobs[0].slot == job.count {
                        try send(packet(dsModel,0x10,0x12,job.replyAddress,Array(repeating:0,count:17)),toKeyboard:false,origin:"bridge-to-app")
                        try log(["event":"catalogue-complete","kind":job.kind,"count":job.count])
                        nameJobs.removeFirst()
                    }
                    try requestNextName()
                    return
                }
                if toKeyboard && [0x10,0x7F].contains(p.device), let supplied = metadata?.request(p,time:ProcessInfo.processInfo.systemUptime) {
                    try log(["event":"message","direction":direction,"original_hex":hex(bytes),"action":supplied.action])
                    try supply(supplied); return
                }
                if !toKeyboard && p.device == translator.device && p.command == 0x12 {
                    metadata?.observe(p,time:ProcessInfo.processInfo.systemUptime)
                }
            }
            let translated = try translator.translate(bytes,toKeyboard:toKeyboard)
            let translatedHex: Any = translated.bytes.map { hex($0) as Any } ?? NSNull()
            try log(["event":"message","direction":direction,"original_hex":hex(bytes),"translated_hex":translatedHex,"action":translated.action])
            if let result = translated.bytes {
                try send(result,toKeyboard:toKeyboard)
                if toKeyboard {
                    if let p = try parse(result,model:translator.model), p.command == 0x12,
                       p.addr == address([0x0F,0,0x20,0]) { previewActive = p.data == [1] }
                    if (try? parse(result,model:translator.model))?.command == 0x11 { snapshot.reads += 1 }
                    else if result.first != 0xF0 || (try? parse(result,model:translator.model))?.command == 0x12 { snapshot.writes += 1 }
                }
            } else if !translated.consumed { snapshot.blocked += 1 }
        } catch let error as BridgeError {
            snapshot.blocked += 1
            try log(["event":"message","direction":direction,"original_hex":hex(bytes),"action":"Blocked: \(error.message)"])
        }
    }
    private func supply(_ reply: MetadataReply) throws {
        for bytes in reply.messages {
            try send(bytes,toKeyboard:false,origin:"bridge-to-app")
            snapshot.supplied += 1
            try log(["event":"bridge-metadata","direction":"bridge-to-app","hex":hex(bytes),"action":reply.action])
        }
    }
    private func requestNextName() throws {
        guard !nameJobs.isEmpty, let translator else { snapshot.activity = ""; return }
        nameJobs[0].attempts += 1; nameJobs[0].lastRequest = ProcessInfo.processInfo.systemUptime
        let job = nameJobs[0]
        snapshot.activity = "Loading \(job.kind) · \(job.slot+1) of \(job.count)"
        try send(packet(translator.model,translator.device,0x11,job.readAddress,encoded(job.size)),toKeyboard:true,origin:"bridge-to-go")
        snapshot.reads += 1
    }
    private func tick(token: Int) {
        queue.asyncAfter(deadline:.now()+0.25) { [weak self] in
            guard let self, self.generation == token, self.snapshot.ready else { return }
            do {
                if let job = self.nameJobs.first, ProcessInfo.processInfo.systemUptime - job.lastRequest > 1.5 {
                    if job.attempts < 2 { try self.requestNextName() }
                    else {
                        self.snapshot.warning = "\(job.kind.capitalized) list incomplete: slot \(job.slot+1) did not answer."
                        try self.send(packet(dsModel,0x10,0x12,job.replyAddress,Array(repeating:0,count:17)),toKeyboard:false,origin:"bridge-to-app")
                        try self.log(["event":"catalogue-incomplete","kind":job.kind,"records":job.slot,"failed_slot":job.slot+1])
                        self.nameJobs.removeFirst(); try self.requestNextName()
                    }
                }
                for reply in self.metadata?.tick(time:ProcessInfo.processInfo.systemUptime) ?? [] {
                    try self.supply(reply); self.snapshot.warning = reply.action
                }
                self.publish(); self.tick(token:token)
            } catch { self.fail(error) }
        }
    }
    private func send(_ bytes: [UInt8], toKeyboard: Bool, origin: String? = nil) throws {
        if toKeyboard {
            let elapsed = ProcessInfo.processInfo.systemUptime - lastSend
            if elapsed < 0.004 { Thread.sleep(forTimeInterval:0.004-elapsed) }
        }
        let size = bytes.count + 128
        let storage = UnsafeMutableRawPointer.allocate(byteCount:size,alignment:MemoryLayout<MIDIPacketList>.alignment)
        defer { storage.deallocate() }
        let list = storage.assumingMemoryBound(to:MIDIPacketList.self)
        let first = MIDIPacketListInit(list)
        let added = bytes.withUnsafeBufferPointer { MIDIPacketListAdd(list,size,first,0,$0.count,$0.baseAddress!) }
        guard Int(bitPattern:added) != 0 else { throw BridgeError(message:"Could not construct MIDI packet") }
        try check(toKeyboard ? MIDISend(output,destination,list) : MIDIReceived(virtualSource,list))
        if toKeyboard { lastSend = ProcessInfo.processInfo.systemUptime }
        try log(["event":"forwarded","direction":origin ?? (toKeyboard ? "app-to-go" : "go-to-app"),"hex":hex(bytes)])
    }
}
