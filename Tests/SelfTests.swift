import Foundation

func runSelfTests() {
    var count = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ label: String) {
        do { guard try condition() else { fatalError("FAIL: \(label)") }; count += 1 }
        catch { fatalError("FAIL: \(label): \(error)") }
    }
    do {
        let t = Translator(model:[0,0,0,0x3C],device:0x11,writesAllowed:false)
        check(try t.translate([0xF0,0x7E,0x10,6,1,0xF7],toKeyboard:true).bytes == [0xF0,0x7E,0x11,6,1,0xF7],"Identity device mapping")
        check(try t.translate([0xF0,0x7E,0x11,6,2,0x41,0x3C,3,0,0,0,3,0,0,0xF7],toKeyboard:false).bytes == dsIdentity,"Exact Tone Manager identity")
        let input = packet(dsModel,0x10,0x11,address([0x1F,0,0,0]),encoded(80))
        let translated = try t.translate(input,toKeyboard:true).bytes!
        check(translated.count == input.count + 1,"Four-byte GO model ID")
        check(try parse(translated,model:t.model)?.addr == address([0x1F,0,0,0]),"No address substitution")
        check(try t.translate([0x90,60,100],toKeyboard:true).bytes == nil,"Read-only blocks notes")
        let editor = Translator(model:t.model,device:t.device,writesAllowed:true)
        for a in [[0x10,0,0,0],[0x14,0x7F,0x7F,0x7F],[0x1F,0,0,0],[0x1F,0x3F,0x7F,0x7F]] {
            check(try editor.translate(packet(dsModel,0x10,0x12,address(a.map(UInt8.init)),[64]),toKeyboard:true).bytes != nil,"Temporary write \(a)")
        }
        for a in [[1,0,0,0],[2,0,0,0],[0x1F,0x40,0,0]] {
            check(try editor.translate(packet(dsModel,0x10,0x12,address(a.map(UInt8.init)),[64]),toKeyboard:true).bytes == nil,"Protected write \(a)")
        }
        check(try editor.translate(packet(dsModel,0x10,0x12,address([1,0,0,0]),[0]),toKeyboard:true).bytes != nil,"Exact Patch mode switch")
        check(try editor.translate(packet(dsModel,0x10,0x12,address([1,0,0,0]),[0,0]),toKeyboard:true).bytes == nil,"Block broad Setup write")
        check(try editor.translate(packet(dsModel,0x10,0x12,address([0x14,127,127,127]),[1,2]),toKeyboard:true).bytes == nil,"Cross-boundary write")
        check(try editor.translate([0xFF],toKeyboard:true).bytes == nil,"System reset blocked")
        let writer = Translator(model:t.model,device:t.device,writesAllowed:true)
        for slot in 0..<128 {
            check(try writer.translate(packet(dsModel,0x10,0x12,address([0x20,UInt8(slot),0,0]),[65]),toKeyboard:true).bytes != nil,"Write performance slot \(slot+1)")
        }
        for slot in 0..<256 {
            let addr = address([UInt8(0x30+slot/128),UInt8(slot%128),0x26,0])
            let result = try writer.translate(packet(dsModel,0x10,0x12,addr,Array(repeating:64,count:154)),toKeyboard:true).bytes!
            check(try parse(result,model:t.model)?.addr == addr,"Native patch slot \(slot+1), full tone block checksum")
        }
        for slot in 0..<8 {
            check(try writer.translate(packet(dsModel,0x10,0x12,address([0x40,UInt8(slot*16),0,0]),[65]),toKeyboard:true).bytes != nil,"Write drum slot \(slot+1)")
        }
        for a in [[0x20,127,127,127],[0x31,127,127,127],[0x40,127,127,127]] {
            check(try writer.translate(packet(dsModel,0x10,0x12,address(a.map(UInt8.init)),[1,2]),toKeyboard:true).bytes == nil,"No stored-range spill \(a)")
        }
        for a in [[1,0,0,0],[2,0,0,0],[0x21,0,0,0],[0x32,0,0,0],[0x41,0,0,0],[0x60,0,0,0]] {
            check(try writer.translate(packet(dsModel,0x10,0x12,address(a.map(UInt8.init)),[64]),toKeyboard:true).bytes == nil,"Allow writes does not enable unsupported writes \(a)")
        }
        check(try writer.translate([0x90,60,100],toKeyboard:true).bytes == [0x90,60,100],"Allow writes enables ordinary MIDI")
        for a in [[0x20,0,0,0],[0x20,127,0,0],[0x30,0,0,0],[0x31,127,0,0],[0x40,0,0,0],[0x40,112,0,0]] {
            check(try t.translate(packet(dsModel,0x10,0x12,address(a.map(UInt8.init)),[65]),toKeyboard:true).bytes == nil,"Allow writes off blocks stored memory \(a)")
        }
        let previewAddress = address([15,0,32,0])
        for value: UInt8 in [0,1] {
            let preview = packet(dsModel,0x10,0x12,previewAddress,[value])
            check(try editor.translate(preview,toKeyboard:true).bytes == packet(t.model,t.device,0x12,previewAddress,[value]),"Native Preview \(value)")
            check(try t.translate(preview,toKeyboard:true).bytes == nil,"Read-only Preview \(value) blocked")
        }
        check(try editor.translate(packet(dsModel,0x10,0x12,previewAddress,[2]),toKeyboard:true).bytes == nil,"Invalid Preview value blocked")
        check(try editor.translate(packet(dsModel,0x10,0x12,previewAddress,[1,0]),toKeyboard:true).bytes == nil,"Broad Preview write blocked")
        for offset: UInt8 in [1,4,7] {
            check(try editor.translate(packet(dsModel,0x10,0x12,address([1,0,0,offset]),[87,0,0]),toKeyboard:true).bytes != nil,"Setup sound selector \(offset)")
        }
        let completion = try writer.translate(packet(dsModel,0x10,0x12,address([15,0,16,1]),[1]),toKeyboard:true)
        check(completion.consumed && completion.bytes == nil,"DS completion is handled without native save command")
        var corrupted = input; corrupted[corrupted.count-2] ^= 1
        do { _ = try t.translate(corrupted,toKeyboard:true); fatalError("Invalid checksum accepted") } catch is BridgeError { count += 1 }
        let f = MIDIFramer()
        check(try f.feed([0x90,60]).isEmpty,"Fragmented MIDI")
        check(try f.feed([100,62,100,0xF0,0x41]) == [[0x90,60,100],[0x90,62,100]],"Running status")
        check(try f.feed([0xF8,0x10,0xF7]) == [[0xF8],[0xF0,0x41,0x10,0xF7]],"Split SysEx and realtime")
        let url = Bundle.main.url(forResource:"go-wave-names",withExtension:"json") ?? URL(fileURLWithPath:"Resources/go-wave-names.json")
        let metadata = try ToneMetadata(url:url)
        let waves = metadata.request(RolandPacket(device:16,command:0x11,addr:address([15,0,1,1]),data:[0,0,0,1]),time:10)!
        check(waves.messages.count == 862,"GO bank A catalogue")
        let wave = try parse(waves.messages[36],model:dsModel)!.data
        check(Array(wave.prefix(4)) == [0,0,2,5],"Wave 37 numbering")
        check(String(bytes:wave.suffix(12),encoding:.ascii)?.trimmingCharacters(in:.whitespaces) == "XPr.P*mp A L","Wave 37 name")
        check(metadata.request(RolandPacket(device:16,command:0x11,addr:address([0x11,0,0,0]),data:encoded(80)),time:10) == nil,"Parameter reads use keyboard requests")
        let performances = metadata.request(RolandPacket(device:16,command:0x11,addr:address([15,0,2,1]),data:[0,64,0,1]),time:10)!
        check(performances.messages.count == 60,"Factory performance catalogue and end marker")
        check(try parse(performances.messages[32],model:dsModel)?.data.prefix(3) == [85,64,32],"Factory performance program 32")
        check(try parse(performances.messages[58],model:dsModel)?.data.prefix(3) == [85,64,58],"Final factory performance program")
        check(metadata.request(RolandPacket(device:16,command:0x11,addr:address([15,0,2,1]),data:[0,0,0,1]),time:10) == nil,"User performance names come from hardware")
        var job = NameCatalogue(RolandPacket(device:16,command:0x11,addr:address([15,0,3,1]),data:[0,0,0,1]))!
        job.slot = 255
        check(job.readAddress == address([0x31,0x7F,0,0]),"Last native user-patch address")
        check(job.record(Array("WaterPiano2 ".utf8)+[2]).prefix(5) == [87,1,127,2,0],"Patch category and program retained")
        check(NameCatalogue(RolandPacket(device:16,command:0x11,addr:address([15,0,2,1]),data:[0,64,0,1])) == nil,"Factory names use separate cached route")
        var drums = NameCatalogue(RolandPacket(device:16,command:0x11,addr:address([15,0,4,1]),data:[0,0,0,1]))!
        drums.slot = 7
        check(drums.readAddress == address([0x40,0x70,0,0]),"Last user drum-kit address")
        check(drums.record(Array("INIT DRUMKIT".utf8)).prefix(5) == [86,0,7,0,0],"Native drum catalogue format")
        let preset = metadata.request(RolandPacket(device:16,command:0x11,addr:address([15,0,3,49]),data:[1,0,0,1]),time:10)!
        check(try parse(preset.messages[0],model:dsModel)?.data.prefix(5) == [87,64,0,1,0],"Cached GO Stage Grand selection and category")
        check(metadata.patches.models["GO:KEYS"]?.count == 1377,"GO:KEYS preset catalogue count")
        check(metadata.patches.models["GO:PIANO"]?.count == 1377,"GO:PIANO preset catalogue count")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let wanted = folder.appendingPathComponent("midi.jsonl")
        let first = try Capture(at:wanted); try first.record(["test":"original"]); first.close()
        let original = try Data(contentsOf:wanted)
        let second = try Capture(at:wanted); check(second.url.lastPathComponent == "midi-1.jsonl","Log collision suffix"); second.close()
        check(try Data(contentsOf:wanted) == original,"Existing capture preserved")
        print("Passed \(count) protocol, editing-boundary, framing, metadata and logging checks.")
    } catch { fatalError("Self-test failed: \(error)") }
}
