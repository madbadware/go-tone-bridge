import SwiftUI
import AppKit

@MainActor final class AppModel: ObservableObject {
    @Published var inputs: [MIDIPort] = []
    @Published var outputs: [MIDIPort] = []
    @Published var source: UInt32 = 0
    @Published var destination: UInt32 = 0
    @Published var writesAllowed = false
    @Published var logging = false
    @Published var snapshot = BridgeSnapshot()
    let engine = BridgeEngine()
    init() {
        engine.onChange = { [weak self] in self?.snapshot = $0 }
        refresh()
    }
    func refresh() {
        inputs = midiPorts(sources:true); outputs = midiPorts(sources:false)
        if !inputs.contains(where:{$0.id == source}) {
            let saved = UserDefaults.standard.string(forKey:"keyboardInput")
            source = inputs.first(where:{$0.name == saved})?.id ?? inputs.first(where:{$0.name.contains("GO:KEYS")})?.id ?? inputs.first(where:{$0.name.contains("GO:PIANO")})?.id ?? inputs.first?.id ?? 0
        }
        matchOutput()
    }
    func matchOutput() {
        let name = inputs.first(where:{$0.id == source})?.name
        destination = outputs.first(where:{$0.name == name})?.id ?? outputs.first(where:{$0.name == UserDefaults.standard.string(forKey:"keyboardOutput")})?.id ?? outputs.first?.id ?? 0
    }
    func start() {
        guard let input = inputs.first(where:{$0.id == source}), let output = outputs.first(where:{$0.id == destination}) else { return }
        guard let waves = Bundle.main.url(forResource:"go-wave-names",withExtension:"json") else {
            snapshot.detail = "Wave-name metadata is missing. Rebuild the app with build.command."; return
        }
        UserDefaults.standard.set(input.name,forKey:"keyboardInput"); UserDefaults.standard.set(output.name,forKey:"keyboardOutput")
        var logURL: URL?
        if logging {
            let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
            logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/GO Tone Bridge/\(formatter.string(from:Date()))-midi.jsonl")
        }
        engine.start(source:input,destination:output,writesAllowed:writesAllowed,logURL:logURL,waveURL:waves)
    }
    func launchToneManager() {
        let url = URL(fileURLWithPath:"/Applications/Roland/JUNO-DS Tone Manager/JUNO-DS Tone Manager.app")
        guard FileManager.default.fileExists(atPath:url.path) else {
            snapshot.detail = "Open your installed JUNO-DS Tone Manager, then select the bridge ports under System."; return
        }
        NSWorkspace.shared.openApplication(at:url,configuration:NSWorkspace.OpenConfiguration())
    }
}

struct BridgeView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(spacing:12) {
                Image(systemName:"pianokeys").font(.system(size:32)).foregroundStyle(.tint)
                VStack(alignment:.leading,spacing:3) {
                    Text("GO Tone Bridge").font(.title2.bold())
                    Text("MIDI bridge for JUNO-DS Tone Manager and Roland GO keyboards.").foregroundStyle(.secondary)
                }
            }
            VStack(spacing:10) {
                Picker("Keyboard input",selection:$model.source) {
                    if model.inputs.isEmpty { Text("No MIDI input found").tag(UInt32(0)) }
                    ForEach(model.inputs) { Text($0.name).tag($0.id) }
                }.onChange(of:model.source) { _ in model.matchOutput() }
                Picker("Keyboard output",selection:$model.destination) {
                    if model.outputs.isEmpty { Text("No MIDI output found").tag(UInt32(0)) }
                    ForEach(model.outputs) { Text($0.name).tag($0.id) }
                }
                HStack {
                    Text("USB or Bluetooth · model detected automatically").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh devices",action:model.refresh)
                }
            }.disabled(model.snapshot.active)
            Divider()
            VStack(alignment:.leading,spacing:8) {
                Toggle("Allow writes",isOn:$model.writesAllowed)
                Text("Enables editing, Preview and Librarian Write. Stored slots may be overwritten.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Record MIDI log",isOn:$model.logging)
                Text("Logs MIDI messages to a local file.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(model.snapshot.active)
            HStack {
                Button(model.snapshot.active ? "Stop" : "Start") {
                    if model.snapshot.active { model.engine.stop() } else { model.start() }
                }.buttonStyle(.bordered).controlSize(.large).fontWeight(.semibold)
                    .disabled(!model.snapshot.active && (model.source == 0 || model.destination == 0))
                Button("Open Tone Manager",action:model.launchToneManager).disabled(!model.snapshot.ready)
                Spacer()
            }
            VStack(alignment:.leading,spacing:9) {
                Label(model.snapshot.state,systemImage:model.snapshot.ready ? "checkmark.circle.fill" : (model.snapshot.active ? "arrow.triangle.2.circlepath" : "circle"))
                    .font(.headline).foregroundStyle(model.snapshot.ready ? .green : .primary)
                Text(model.snapshot.detail).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
                if !model.snapshot.activity.isEmpty {
                    Text(model.snapshot.activity).font(.caption).monospacedDigit()
                }
                if model.snapshot.ready || model.snapshot.reads > 0 {
                    HStack(spacing:12) {
                        ForEach(Array(zip(["Reads (RQ1)","Writes/MIDI","Received","Blocked"],
                                          [model.snapshot.reads,model.snapshot.writes,model.snapshot.received,model.snapshot.blocked])),id:\.0) { label,value in
                            VStack(alignment:.leading,spacing:3) {
                                Text(label).foregroundStyle(.secondary)
                                Text("\(value)").monospacedDigit()
                            }.frame(maxWidth:.infinity,alignment:.leading)
                        }
                    }.font(.caption)
                }
                if !model.snapshot.warning.isEmpty {
                    Label(model.snapshot.warning,systemImage:"info.circle").font(.caption).foregroundStyle(.orange)
                }
                if let log = model.snapshot.logURL {
                    Button("Show log") { NSWorkspace.shared.activateFileViewerSelecting([log]) }.font(.caption)
                }
            }.padding(14).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary, in:RoundedRectangle(cornerRadius:10))
            HStack {
                Text("Version \(appVersion)").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Help") {
                    if let notes = Bundle.main.url(forResource:"Usage",withExtension:"html") { NSWorkspace.shared.open(notes) }
                }.buttonStyle(.link).font(.caption)
            }
        }.padding(24).frame(width:560).frame(minHeight:540)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var engine: BridgeEngine?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { engine?.shutdown() }
}
struct ToneBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var model = AppModel()
    var body: some Scene {
        WindowGroup("GO Tone Bridge") {
            BridgeView().environmentObject(model).onAppear { delegate.engine = model.engine }
        }.windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing:.newItem) {}
        }
    }
}
@main struct EntryPoint {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            runSelfTests(); return
        }
        ToneBridgeApp.main()
    }
}
