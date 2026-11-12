import SwiftUI
import UniformTypeIdentifiers

/// The UEFI firmware a Windows machine starts from: EDK2's ArmVirtQemu, as QEMU ships it, carried in the
/// app gzipped (scripts/fetch_uefi.sh) and unpacked once to where the engine can read it.
enum WindowsFirmware {
    static let missing = "This build of Henge has no UEFI firmware (ios/scripts/fetch_uefi.sh fetches it before a build)."

    static var bundled: URL? { Bundle.main.url(forResource: "edk2-aarch64-code.fd", withExtension: "gz") }

    /// The unpacked firmware's path, or nil when the app carries none or it could not be unpacked.
    static func path() -> String? {
        guard let packed = bundled else { return nil }
        let fm = FileManager.default
        let dir = Machines.root.appendingPathComponent("Firmware", isDirectory: true)
        let file = dir.appendingPathComponent("edk2-aarch64-code.fd"), stamp = dir.appendingPathComponent("stamp")
        // Unpacked again when the app's copy changes: its size and the build say which it is.
        let size = (try? fm.attributesOfItem(atPath: packed.path)[.size] as? Int64) ?? 0
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let want = "\(size) \(build)"
        if fm.fileExists(atPath: file.path), (try? String(contentsOf: stamp, encoding: .utf8)) == want { return file.path }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard henge_gunzip(packed.path, file.path) == 0 else {
            HengeLog.log("windows", "the UEFI firmware could not be unpacked")
            return nil
        }
        try? want.write(to: stamp, atomically: true, encoding: .utf8)
        return file.path
    }
}

/// What Setup needs typed for it, as the session's Details offers (SessionView).
enum WindowsSetup {
    /// Setup reads these when it checks the machine: no TPM, no Secure Boot, and less memory than it asks for.
    static let requirements = ["BypassTPMCheck", "BypassSecureBootCheck", "BypassRAMCheck"]
        .map { "reg add HKLM\\SYSTEM\\Setup\\LabConfig /v \($0) /t REG_DWORD /d 1 /f" }
        .joined(separator: " & ") + " & exit\n"
    static let noNetwork = "oobe\\bypassnro\n"
    /// Windows' boot manager picks the display's size, from what the firmware offers: the largest is 1024 x 768.
    static let largerScreen = "bcdedit /set {globalsettings} highestmode on\n"

    /// Installs UTM's Direct3D driver from its guest tools disc, which is in drive D: when it is the only disc.
    static let gpuDriver = "pnputil /add-driver D:\\Drivers\\viogpu3d\\w11\\ARM64\\viogpu3d.inf /install"
    /// The disc: UTM's guest tools, from the driver's own releases (github.com/osy/kvm-guest-drivers-windows, v0.5).
    static let toolsURL = URL(string: "https://github.com/osy/kvm-guest-drivers-windows/releases/download/v0.5/utm-guest-tools-0.1.275.iso")!

    /// Typed into a window that is open already.
    @MainActor static func typeHere(_ command: String) async {
        for c in command {
            Keys.type(c)
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
    }

    /// Shift-F10 opens Setup's command prompt; then the command, a key at a time (a USB keyboard's reports
    /// reach Windows one every few milliseconds).
    @MainActor static func type(_ command: String) async {
        henge_vm_key(Keys.shift, 1)
        Keys.press(68) // F10
        henge_vm_key(Keys.shift, 0)
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        for c in command {
            Keys.type(c)
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
    }
}

/// Makes Windows machines: a blank disk beside an installation disc (an ISO from Files), or a disk brought in.
@MainActor
final class WindowsInstaller: ObservableObject {
    static let shared = WindowsInstaller()

    @Published private(set) var working: String?
    @Published fileprivate(set) var copied: Double = 0
    @Published var failure: String?

    var busy: Bool { working != nil }

    /// A new machine with a blank disk of diskGB (a sparse file: it takes space as Windows fills it) and the
    /// ISO as its installation disc. Starting it starts Setup.
    func create(from iso: URL, name: String, ramMB: Int, diskGB: Int, guestOS: String = "Windows") {
        make(name: name, ramMB: ramMB, working: "Copying \(iso.lastPathComponent)…", source: iso, guestOS: guestOS) { mac in
            let fm = FileManager.default
            guard fm.createFile(atPath: mac.disk.path, contents: nil) else { throw Self.message("The disk could not be made.") }
            let handle = try FileHandle(forWritingTo: mac.disk)
            try handle.truncate(atOffset: UInt64(diskGB) << 30)
            try handle.close()
            return mac.media
        }
    }

    /// A raw disk with Windows on it already (made by hengevm on a Mac, for one): copied in as a new machine.
    /// One packed with its holes left out (build/hvsparse pack, as tools/export_ios.sh packs a Mac's) is unpacked.
    func importDisk(_ url: URL, ramMB: Int) {
        var name = url.deletingPathExtension().lastPathComponent
        if url.pathExtension == "hvsparse" { name = (name as NSString).deletingPathExtension }
        make(name: name, ramMB: ramMB, working: "Bringing in \(url.lastPathComponent)…",
             source: url) { $0.disk }
    }

    /// The disc with the GPU driver, downloaded into the machine's folder (about 140 MB).
    func downloadTools(_ mac: VirtualMac) {
        guard !busy else { return }
        working = "Downloading the GPU driver disc…"
        copied = 0
        failure = nil
        Task {
            defer { working = nil }
            do {
                let (file, response) = try await URLSession.shared.download(from: WindowsSetup.toolsURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Self.message("The driver disc could not be downloaded.") }
                try? FileManager.default.removeItem(at: mac.tools)
                try FileManager.default.moveItem(at: file, to: mac.tools)
                HengeLog.log("windows", "the GPU driver disc is in \(mac.name)'s drive")
            } catch {
                failure = error.localizedDescription
            }
            objectWillChange.send()
        }
    }

    func removeTools(_ mac: VirtualMac) {
        try? FileManager.default.removeItem(at: mac.tools)
        objectWillChange.send()
    }

    /// The installation disc is several GB that nothing needs once Windows is on the disk.
    func removeMedia(_ mac: VirtualMac) {
        try? FileManager.default.removeItem(at: mac.media)
        objectWillChange.send()
    }

    /// Copies source to where prepare says (after it has made what else the machine needs), and lists the machine.
    private func make(name: String, ramMB: Int, working text: String, source: URL, guestOS: String = "Windows",
                      prepare: @escaping @Sendable (VirtualMac) throws -> URL) {
        guard !busy else { return }
        working = text
        copied = 0
        failure = nil
        UIApplication.shared.isIdleTimerDisabled = true // a locked screen would suspend the copy
        Task {
            defer { working = nil; UIApplication.shared.isIdleTimerDisabled = false }
            var mac = VirtualMac(name: name, ecid: 0, seed: 0, ramMB: ramMB, diskBytes: 0)
            mac.system = "windows"
            mac.osName = guestOS
            (mac.screenWidth, mac.screenHeight) = Device.windowsScreen
            let fm = FileManager.default
            do {
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                let total = (try? fm.attributesOfItem(atPath: source.path)[.size] as? Int64) ?? 0
                let free = (try? Machines.root.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                    .volumeAvailableCapacityForImportantUsage ?? 0
                if free > 0 && free < total + (4 << 30) {
                    throw Self.message("This needs about \(ByteText.string(UInt64(total + (4 << 30)))) free; this \(Device.name) has \(ByteText.string(UInt64(free))).")
                }
                try fm.createDirectory(at: mac.directory, withIntermediateDirectories: true)
                Machines.excludeFromBackup(Machines.root)
                let made = mac
                let target = try prepare(made)
                let watch = Task {
                    while !Task.isCancelled {
                        let done = (try? fm.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? 0
                        copied = Double(done) / Double(max(total, 1))
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                }
                defer { watch.cancel() }
                if source.pathExtension == "hvsparse" {
                    watch.cancel() // the unpacking says how far it is
                    let ok = await Task.detached {
                        hv_sparse_unpack(source.path, target.path, { done, total, _ in
                            let fraction = Double(done) / Double(max(total, 1))
                            Task { @MainActor in WindowsInstaller.shared.copied = fraction }
                        }, nil) == 0
                    }.value
                    guard ok else { throw Self.message("\(source.lastPathComponent) could not be unpacked (not enough space?).") }
                } else {
                    try await Task.detached { try FileManager.default.copyItem(at: source, to: target) }.value
                }
                mac.diskBytes = (try? fm.attributesOfItem(atPath: mac.disk.path)[.size] as? Int64) ?? 0
                let info = MachineFile(name: mac.name, system: "windows", ecid: 0, seed: 0, ramMB: mac.ramMB)
                try JSONEncoder().encode(info).write(to: mac.directory.appendingPathComponent("machine.json"))
                try guestOS.write(to: mac.directory.appendingPathComponent(Machines.installedMarker), atomically: true, encoding: .utf8)
                Machines.shared.add(mac)
                HengeLog.log("windows", "made \(mac.name) from \(source.lastPathComponent) (\(mac.diskBytes >> 30) GB disk)")
            } catch {
                try? fm.removeItem(at: mac.directory)
                failure = error.localizedDescription
                HengeLog.log("windows", "\(source.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    nonisolated private static func message(_ text: String) -> NSError {
        NSError(domain: "Henge", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

/// Windows machines, beside the Macs and Linux: the one used last with Start, the others, and adding one.
struct WindowsView: View {
    @ObservedObject private var machines = Machines.shared
    @ObservedObject private var installer = WindowsInstaller.shared
    @ObservedObject private var jit = JITCoordinator.shared
    @Binding var running: VirtualMac?
    @State private var jitReady = JITBootstrap.ready
    @State private var chosen: UUID?
    @State private var pickingISO = false
    @State private var pickingDisk = false
    @State private var ramGB = min(max(Device.suggestedRAMGB, 2), 4)
    @State private var diskGB = 64
    @State private var isoSystem = "Linux"
    @AppStorage("henge.cpus") private var cpus = 4

    private var all: [VirtualMac] { machines.all.filter(\.isWindows) }

    private var shown: VirtualMac? {
        if let chosen, let m = all.first(where: { $0.id == chosen }) { return m }
        return all.max { ($0.lastUsed ?? $0.added) < ($1.lastUsed ?? $1.added) }
    }

    private static let iso = UTType(filenameExtension: "iso") ?? .diskImage

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    progress
                    if let m = shown {
                        hero(m)
                        others(besides: m)
                    }
                    add
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .deskColumn()
            }
            .background(Desk.page)
            .navigationTitle("ISO VM")
            .navigationDestination(for: VirtualMac.self) { WindowsSettingsView(machine: $0) }
            // Two importers on one view: only the last would work, so each has a view of its own.
            .background {
                Color.clear.fileImporter(isPresented: $pickingISO, allowedContentTypes: [Self.iso, .diskImage, .data]) { result in
                    guard case let .success(url) = result else { return }
                    guard url.pathExtension.lowercased() == "iso" else {
                        installer.failure = "Choose an ARM64 installation file ending in .iso."
                        return
                    }
                    let n = all.filter { $0.osName == isoSystem }.count
                    installer.create(from: url, name: n == 0 ? isoSystem : "\(isoSystem) \(n + 1)",
                                     ramMB: ramGB * 1024, diskGB: diskGB, guestOS: isoSystem)
                }
            }
            .background {
                Color.clear.fileImporter(isPresented: $pickingDisk, allowedContentTypes: [.data, .diskImage]) { result in
                    if case let .success(url) = result { installer.importDisk(url, ramMB: ramGB * 1024) }
                }
            }
            .task {
                while !Task.isCancelled {
                    jitReady = JITBootstrap.ready
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    // MARK: The machine on show

    private func hero(_ m: VirtualMac) -> some View {
        VStack(spacing: 0) {
            NavigationLink(value: m) {
                VStack(spacing: 0) {
                    ZStack {
                        Desk.raised.opacity(0.5)
                        if let image = UIImage(contentsOfFile: MacPreview.file(for: m).path) {
                            Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "pc")
                                .font(.system(size: 46, weight: .light))
                                .foregroundStyle(Desk.faint)
                        }
                    }
                    .aspectRatio(m.aspect, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 0.5))
                    HStack {
                        Text(m.name).font(.system(size: 24, weight: .bold)).foregroundStyle(Desk.text).lineLimit(1)
                        Spacer()
                        Text(jitReady ? "JIT on" : "JIT off")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(jitReady ? Desk.good : Desk.warn)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background((jitReady ? Desk.good : Desk.warn).opacity(0.13), in: Capsule())
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Desk.faint)
                    }
                    .padding(.top, 15)
                    .padding(.horizontal, 5)
                    Text("\(m.summary) · \(cpus) CPUs · \(ByteText.string(UInt64(max(m.bytesUsed, 0)))) on disk")
                        .font(.system(size: 15))
                        .foregroundStyle(Desk.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 5)
                        .padding(.top, 3)
                    if FileManager.default.fileExists(atPath: m.media.path) {
                        Text(m.isUEFILinux ? "The installation disc is in its drive. Start the machine to try its installer." : "The installation disc is in its drive. Starting a machine with nothing on its disk starts Setup: see Details in the session for what Setup needs typed.")
                            .font(.system(size: 13))
                            .foregroundStyle(Desk.dim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 5)
                            .padding(.top, 6)
                    }
                }
            }
            .buttonStyle(.plain)
            if WindowsFirmware.bundled == nil {
                Text(WindowsFirmware.missing).font(.system(size: 13)).foregroundStyle(Desk.warn)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 5)
                    .padding(.top, 10)
            } else if jitReady {
                Button { running = m } label: { Label("Start", systemImage: "play.fill") }
                    .buttonStyle(DeskButtonStyle())
                    .padding(.top, 15)
            } else {
                Text(JITBootstrap.lastFailure ?? jit.automaticDescription).font(.system(size: 13)).foregroundStyle(Desk.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 5)
                    .padding(.top, 10)
                Button("Turn On JIT") { jit.enable() }
                    .buttonStyle(DeskButtonStyle())
                    .padding(.top, 15)
            }
        }
        .padding(14)
        .deskCard(radius: 30)
    }

    @ViewBuilder private func others(besides shown: VirtualMac) -> some View {
        let rest = all.filter { $0.id != shown.id }
        if !rest.isEmpty {
            DeskHeading("Other ISO machines")
            VStack(spacing: 0) {
                ForEach(rest) { other in
                    Button { chosen = other.id } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(other.name).font(.system(size: 16, weight: .medium)).foregroundStyle(Desk.text)
                                Text(other.summary).font(.system(size: 13)).foregroundStyle(Desk.dim)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Desk.faint)
                        }
                        .padding(.horizontal, 17)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    if other.id != rest.last?.id { Rectangle().fill(Desk.hairline).frame(height: 0.5) }
                }
            }
            .deskCard()
        }
    }

    // MARK: Adding one

    @ViewBuilder private var progress: some View {
        if let working = installer.working {
            VStack(alignment: .leading, spacing: 10) {
                Text(working).font(.system(size: 15))
                DeskBar(fraction: installer.copied)
                Text("Keep Henge open. The screen stays on until it is done.").font(.system(size: 13)).foregroundStyle(Desk.dim)
            }
            .padding(15)
            .deskCard()
        }
        if let failure = installer.failure {
            Button { installer.failure = nil } label: {
                NoticeRow(symbol: "exclamationmark.triangle.fill", text: failure, trailing: "OK", tint: Desk.bad)
            }
        }
    }

    private var add: some View {
        VStack(alignment: .leading, spacing: 14) {
            if all.isEmpty {
                Image(systemName: "pc")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(Desk.accentLight)
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .background(Desk.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text("No ISO machines yet").font(.system(size: 24, weight: .bold)).frame(maxWidth: .infinity)
            } else {
                Text("Add an ISO machine").font(.system(size: 20, weight: .bold))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Install from an ARM64 ISO").font(.system(size: 17, weight: .semibold))
                Text("Choose an ARM64 installer ISO saved in Files. Linux ISO boot is experimental and requires a UEFI-compatible installer; compatibility varies by distribution.")
                    .font(.system(size: 13)).foregroundStyle(Desk.dim)
                Text("Setup can take a long time. The ISO is copied into the machine until you remove its installation disc.")
                    .font(.system(size: 13)).foregroundStyle(Desk.dim)
            }
            Picker("Operating system", selection: $isoSystem) {
                Text("Linux").tag("Linux")
                Text("Windows").tag("Windows")
            }
            .pickerStyle(.segmented)
            .disabled(installer.busy)
            Stepper("Memory: \(ramGB) GB", value: $ramGB, in: 2...max(Device.suggestedRAMGB, 2))
                .font(.system(size: 15))
            Stepper("Disk: up to \(diskGB) GB", value: $diskGB, in: 32...256, step: 16)
                .font(.system(size: 15))
            Button("Install from an ISO…") { pickingISO = true }
                .buttonStyle(DeskButtonStyle(enabled: !installer.busy))
                .disabled(installer.busy)
            Button("Bring in a Windows disk image…") { pickingDisk = true }
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.accentLight)
                .frame(maxWidth: .infinity)
                .disabled(installer.busy)
            Text("A raw disk (.img) with Windows on Arm on it already, as hengevm on a Mac installs it. UEFI firmware starts it, from its EFI partition.")
                .font(.system(size: 12)).foregroundStyle(Desk.faint)
        }
        .padding(16)
        .deskCard(radius: 30)
    }
}

/// One Windows machine: its name, memory and CPUs, its installation disc, and deleting it.
struct WindowsSettingsView: View {
    @ObservedObject private var machines = Machines.shared
    @ObservedObject private var installer = WindowsInstaller.shared
    @Environment(\.dismiss) private var dismiss
    @State private var machine: VirtualMac
    @State private var confirmDelete = false
    @AppStorage("henge.cpus") private var cpus = 4

    init(machine: VirtualMac) { _machine = State(initialValue: machine) }

    private var mediaBytes: Int64 {
        (try? FileManager.default.attributesOfItem(atPath: machine.media.path)[.size] as? Int64) ?? 0
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                DeskHeading("Name")
                TextField("Name", text: $machine.name)
                    .font(.system(size: 16))
                    .submitLabel(.done)
                    .padding(.horizontal, 17)
                    .padding(.vertical, 14)
                    .deskCard()
                    .onSubmit { machines.update(machine) }

                DeskHeading("Memory")
                Stepper("\(machine.ramMB / 1024) GB", value: Binding(get: { machine.ramMB / 1024 },
                                                                       set: { machine.ramMB = $0 * 1024; machines.update(machine) }),
                        in: Device.memoryChoices)
                    .font(.system(size: 16))
                    .padding(.horizontal, 17)
                    .padding(.vertical, 10)
                    .deskCard()

                DeskHeading("Processors")
                Stepper("\(cpus) CPUs", value: $cpus, in: 1...6)
                    .font(.system(size: 16))
                    .padding(.horizontal, 17)
                    .padding(.vertical, 10)
                    .deskCard()

                DeskHeading("Screen")
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Size", selection: Binding(get: { machine.screen.width }, set: { width in
                        (machine.screenWidth, machine.screenHeight) = Device.windowsScreen(width: width)
                        machines.update(machine)
                    })) {
                        ForEach(Device.windowsWidths, id: \.self) { width in
                            let size = Device.windowsScreen(width: width)
                            Text("\(size.width) × \(size.height)").tag(width)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(machine.isUEFILinux ? "The screen size takes effect at the next start. Linux ISO support is experimental; a larger screen may be slower." : "The shape of this \(Device.name)'s screen, from the next start. Windows draws with the emulated CPUs (it has no display driver for this machine), so a larger screen is slower. This is the largest size Windows offers: a Windows installed at another size keeps it until this one is chosen in its Settings, System, Display.")
                        .font(.system(size: 13)).foregroundStyle(Desk.dim)
                }
                .padding(17)
                .frame(maxWidth: .infinity, alignment: .leading)
                .deskCard()

                DeskHeading("Touch")
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Touch Screen", isOn: Binding(get: { machine.touchAsTrackpad != true }, set: {
                        machine.touchAsTrackpad = $0 ? nil : true
                        machines.update(machine)
                    }))
                        .font(.system(size: 16))
                    Text("The guest sees your fingers where they touch the picture, if it supports the virtual touch screen. Turn this off to use the picture as a trackpad.")
                        .font(.system(size: 13)).foregroundStyle(Desk.dim)
                }
                .padding(17)
                .frame(maxWidth: .infinity, alignment: .leading)
                .deskCard()

                if !machine.isUEFILinux {
                DeskHeading("GPU")
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("GPU", isOn: Binding(get: { machine.gpu != false }, set: {
                        machine.gpu = $0
                        if !$0 { machine.gpuDriver = nil } // back to the firmware's screen, should the driver be at fault
                        machines.update(machine)
                    }))
                        .font(.system(size: 16))
                    Text(EngineTuning.windowsGPU == nil
                         ? "This build of Henge has no GPU frameworks for Windows (ios/scripts/fetch_virgl.sh)."
                         : machine.gpuDriver == true
                         ? "Windows has the driver: the GPU is its only screen, and nothing shows while it starts, until the driver does. The size that fits this session is offered to Windows as it changes: choose it in Windows' Settings, System, Display. If the screen stays black, turn this off and on again: Windows starts on the firmware's screen once more."
                         : "Windows uses it once UTM's Direct3D 11 driver is installed in it (experimental: some of Windows' own interface is drawn with pieces missing). Until then, and with this off, Windows draws with the emulated CPUs.")
                        .font(.system(size: 13)).foregroundStyle(Desk.dim)
                    if FileManager.default.fileExists(atPath: machine.tools.path) {
                        Text("The driver disc is in the machine's drive (D: in Windows, when there is no installation disc). The session's Details type the command that installs the driver.")
                            .font(.system(size: 13)).foregroundStyle(Desk.dim)
                        Button("Remove the Driver Disc", role: .destructive) { installer.removeTools(machine) }
                            .font(.system(size: 15, weight: .semibold))
                    } else {
                        Button(installer.working ?? "Download the Driver Disc (140 MB)") { installer.downloadTools(machine) }
                            .font(.system(size: 15, weight: .semibold))
                            .disabled(installer.busy)
                    }
                    if let failure = installer.failure { Text(failure).font(.system(size: 13)).foregroundStyle(Desk.bad) }
                }
                .padding(17)
                .frame(maxWidth: .infinity, alignment: .leading)
                .deskCard()
                }

                if mediaBytes > 0 {
                    DeskHeading("Installation disc")
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(ByteText.string(UInt64(mediaBytes))), in the machine's USB CD-ROM drive. Remove it after installation when the installer asks you to eject the disc.")
                            .font(.system(size: 14)).foregroundStyle(Desk.dim)
                        Button("Remove the Disc", role: .destructive) { installer.removeMedia(machine) }
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .padding(17)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .deskCard()
                }

                DeskHeading("")
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Delete \(machine.name)", systemImage: "trash").frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(17)
                .deskCard()
            }
            .padding(.horizontal, 16)
            .deskColumn()
        }
        .background(Desk.page)
        .navigationTitle(machine.name)
        .confirmationDialog("Delete \(machine.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                machines.delete(machine.id)
                dismiss()
            }
        } message: {
            Text("Its disk is removed from this \(Device.name).")
        }
    }
}
