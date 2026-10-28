import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// Main screen: what is being sent, the start button, what to show (video from Photos or a link, camera, test patterns)
// and the speed. Everything else (smoothness tricks, method, log) is in the settings sheet.
struct CarPlayView: View {
    @ObservedObject var screen: CarScreen
    @State private var pickedVideo: PhotosPickerItem?
    // While a video is coming from Photos (it may download from iCloud; big files take a while)
    @State private var importProgress: Progress?
    @State private var showLink = false
    @State private var showSettings = false
    // The screen is redrawn when the language changes; L() reads the same setting
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.current.rawValue

    var body: some View {
        List {
            Section {
                StatusCard(screen: screen)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                startButton
                    .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } footer: {
                Text(L("In the car, open Now Playing in CarPlay. If you don't see the artwork, turn on \"Show Album Art\" in CarPlay settings.", "Arabada CarPlay'de Şimdi Çalıyor'u aç. Kapak görünmüyorsa CarPlay ayarlarında \"Albüm kapağını göster\"i aç."))
            }

            Section {
                Picker(L("Source", "Kaynak"), selection: $screen.source) {
                    ForEach(CarScreen.Source.allCases) { Text($0.shortName).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)

                switch screen.source {
                case .video:
                    currentVideo
                    videoButtons
                case .camera:
                    Picker(L("Camera", "Kamera"), selection: $screen.cameraPosition) {
                        ForEach(CameraCapture.Position.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if let status = screen.cameraStatus {
                        Text(status).font(.caption).foregroundStyle(.red)
                    }
                default:
                    EmptyView()
                }

                Picker(selection: $screen.fps) {
                    ForEach(CarScreen.fpsChoices, id: \.self) { Text(L("\(Int($0)) fps", "\(Int($0)) kare/sn")).tag($0) }
                } label: {
                    Label(L("Speed", "Hız"), systemImage: "speedometer")
                }
            } header: {
                Text(L("What to show", "Ne gösterilsin"))
            } footer: {
                Text(sourceFooter)
            }
        }
        .id(language)
        .navigationTitle("Video on CarPlay")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker(L("Language", "Dil"), selection: $language) {
                        ForEach(AppLanguage.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                } label: {
                    Image(systemName: "globe")
                }
                .accessibilityLabel(L("Language", "Dil"))
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel(L("Settings", "Ayarlar"))
            }
        }
        .sheet(isPresented: $showLink) { LinkSheet(screen: screen) }
        .sheet(isPresented: $showSettings) { SettingsSheet(screen: screen) }
        .onChange(of: pickedVideo) { _, item in
            guard let item else { return }
            importVideo(item)
        }
    }

    private var startButton: some View {
        Button {
            if screen.isRunning { screen.stop() } else { screen.start() }
        } label: {
            Label(screen.isRunning ? L("Stop", "Durdur") : L("Start sending to the car", "Arabaya göndermeye başla"),
                  systemImage: screen.isRunning ? "stop.fill" : "play.fill")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(screen.isRunning ? .red : .green)
    }

    // The chosen video, the import progress or a hint
    @ViewBuilder private var currentVideo: some View {
        if let progress = importProgress {
            ImportRow(progress: progress)
        } else if let name = screen.videoName {
            HStack(spacing: 12) {
                Image(systemName: "film.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).lineLimit(1)
                    if let status = screen.videoStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        } else {
            Text(screen.videoStatus ?? L("No video yet: pick one from Photos or open a YouTube link.", "Henüz video yok: galeriden seç ya da YouTube linki aç."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // Two equal buttons: Photos and YouTube (the link is typed in its own sheet)
    private var videoButtons: some View {
        HStack(spacing: 12) {
            // .current: take the video as it is. By default Photos may convert it to a compatible format, which takes long.
            PhotosPicker(selection: $pickedVideo, matching: .videos, preferredItemEncoding: .current) {
                Label(L("Photos", "Galeri"), systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .disabled(importProgress != nil)
            Button {
                showLink = true
            } label: {
                Label("YouTube", systemImage: "play.rectangle.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(.red)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .font(.body.weight(.semibold))
    }

    private var sourceFooter: String {
        switch screen.source {
        case .video:
            L("The sound comes from the car's speakers, the picture from the artwork.", "Ses arabanın hoparlöründen, görüntü kapak resminden gelir.")
        case .camera:
            L("The camera only works while this app is on the screen (an iOS rule), so the phone stays awake. Use it only while parked.",
              "Kamera yalnızca uygulama ekrandayken çalışır (iOS kuralı), bu yüzden telefon uyumaz. Sadece park hâlindeyken kullan.")
        case .counter, .animation:
            L("Test pattern: the frame number in the picture shows how many frames reach the car.", "Test deseni: resimdeki kare numarası arabaya kaç kare ulaştığını gösterir.")
        }
    }

    private func importVideo(_ item: PhotosPickerItem) {
        let progress = item.loadTransferable(type: MovieFile.self) { result in
            Task { @MainActor in
                importProgress = nil
                pickedVideo = nil // so the same video can be picked again
                switch result {
                case .success(let movie?):
                    screen.loadVideo(movie.url, name: movie.url.deletingPathExtension().lastPathComponent)
                case .success(nil):
                    screen.videoImportFailed(L("Could not get the video", "Video alınamadı"))
                case .failure(let error):
                    screen.videoImportFailed(L("Could not get the video: \(error.localizedDescription)", "Video alınamadı: \(error.localizedDescription)"))
                }
            }
        }
        importProgress = progress
    }
}

// Opening a YouTube (or mp4 / m3u8) link: paste, open, the sheet closes when the video is ready
private struct LinkSheet: View {
    @ObservedObject var screen: CarScreen
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var loading = false
    @State private var failed = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("YouTube link", "YouTube linki"), text: $link, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .focused($focused)
                        .onSubmit(open)
                    PasteButton(payloadType: String.self) { strings in
                        guard let text = strings.first else { return }
                        link = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        open()
                    }
                } footer: {
                    Text(L("mp4 and m3u8 links work too.", "mp4 ve m3u8 linkleri de olur."))
                }
                if loading || failed, let status = screen.videoStatus {
                    Section {
                        HStack(spacing: 10) {
                            if loading { ProgressView() }
                            Text(status)
                                .font(.callout)
                                .foregroundStyle(failed ? .red : .secondary)
                        }
                    }
                }
            }
            .navigationTitle(L("Open a link", "Linkten aç"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel", "Vazgeç")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if loading {
                        ProgressView()
                    } else {
                        Button(L("Open", "Aç"), action: open).disabled(link.isEmpty)
                    }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func open() {
        guard !link.isEmpty, !loading else { return }
        loading = true
        failed = false
        Task {
            let ok = await screen.loadLink(link)
            loading = false
            if ok { dismiss() } else { failed = true }
        }
    }
}

// Smoothness tricks, the video method, the test tone and the log
private struct SettingsSheet: View {
    @ObservedObject var screen: CarScreen
    @Environment(\.dismiss) private var dismiss
    @State private var showLog = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $screen.skipWait) {
                        Label(L("Skip the iOS wait", "iOS'un beklemesini atla"), systemImage: "hare")
                    }
                    .disabled(!screen.canSkipWait)
                    Toggle(isOn: $screen.sameTrack) {
                        Label(L("Every frame is the same track", "Her kare aynı şarkı sayılsın"), systemImage: "music.note")
                    }
                } header: {
                    Text(L("Smoothness", "Akıcılık"))
                } footer: {
                    Text(screen.canSkipWait
                         ? L("iOS collects artwork changes and passes them on every half second; skipping the wait sends every frame right away. If the car sometimes shows its empty artwork, lower the speed.",
                             "iOS kapak değişikliklerini biriktirip yarım saniyede bir iletiyor; bekleme atlanınca her kare hemen gider. Araba arada boş kapak gösteriyorsa hızı düşür.")
                         : L("No way to skip the wait was found on this iOS version; iOS passes on about 2 frames per second.",
                             "Bu iOS sürümünde beklemeyi atlamanın yolu bulunamadı; iOS saniyede yaklaşık 2 kare iletir."))
                }

                Section {
                    Picker(L("Method", "Yöntem"), selection: $screen.method) {
                        ForEach(CarScreen.Method.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if screen.method == .frames {
                        Toggle(isOn: $screen.fillSquare) {
                            Label(L("Fill the square (crop the video)", "Kareyi doldur (videoyu kırp)"), systemImage: "crop")
                        }
                    } else if let status = screen.animatedStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text(L("Video method", "Video yöntemi"))
                } footer: {
                    Text(screen.method == .frames
                         ? L("Frame by frame: every frame is sent as the artwork.", "Kare kare: her kare kapak olarak gönderilir.")
                         : L("Animated artwork (iOS 26): the system plays a 2-minute clip cut from the video by itself. Supported kinds: \(screen.animatedSupport).",
                             "Hareketli kapak (iOS 26): videodan kırpılmış 2 dakikalık bir klibi sistem kendisi oynatır. Desteklenen türler: \(screen.animatedSupport)."))
                }

                Section {
                    Toggle(isOn: $screen.audible) {
                        Label(L("Audible test tone", "Duyulur test tonu"), systemImage: "waveform")
                    }
                    DisclosureGroup(isExpanded: $showLog) {
                        if screen.log.isEmpty {
                            Text(L("Nothing logged yet", "Henüz kayıt yok")).foregroundStyle(.secondary)
                        }
                        ForEach(screen.log, id: \.self) { Text($0).font(.caption.monospaced()) }
                    } label: {
                        Label(L("Log", "Kayıt"), systemImage: "list.bullet.rectangle")
                            .badge(screen.log.count)
                    }
                } header: {
                    Text(L("Other", "Diğer"))
                } footer: {
                    Text(L("In the car, ⏭ raises the speed, ⏮ switches the source, ⏯ pauses or resumes. Presses show up in the log.", "Arabadaki ⏭ hızı artırır, ⏮ kaynağı değiştirir, ⏯ durdurur ya da sürdürür. Basılanlar kayıtta görünür."))
                }
            }
            .navigationTitle(L("Settings", "Ayarlar"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done", "Tamam")) { dismiss() }
                }
            }
        }
        // Half height first: the status card stays visible above, so a toggle's effect on the frame rate shows right away
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }
}

// A card that looks like the car's screen: the frame being sent and how many frames iOS really passes on
private struct StatusCard: View {
    @ObservedObject var screen: CarScreen

    var body: some View {
        HStack(spacing: 16) {
            Group {
                if let preview = screen.preview {
                    Image(uiImage: preview).resizable().scaledToFill()
                } else {
                    ZStack {
                        Color.white.opacity(0.08)
                        Image(systemName: "car.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.35))
                    }
                }
            }
            .frame(width: 128, height: 128)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(screen.isRunning ? Color.green : Color.gray).frame(width: 8, height: 8)
                    Text(screen.isRunning ? L("Sending to the car", "Arabaya gidiyor") : L("Ready", "Hazır"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
                Text(screen.isRunning ? "\(screen.deliveredFPS)" : "–")
                    .font(.system(size: 52, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(numberColor)
                    .contentTransition(.numericText())
                Text(L("fps passed on", "kare/sn iletiliyor"))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                Text(screen.isRunning ? L("we give \(screen.sentFPS) · frame \(screen.frameNumber)", "biz \(screen.sentFPS) veriyoruz · kare \(screen.frameNumber)") : L("target \(Int(screen.fps)) fps", "hedef \(Int(screen.fps)) kare/sn"))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
                // Image sizes iOS asked for in the last second: a second size likely means the car asks by itself
                if screen.isRunning, !screen.requestedSizes.isEmpty {
                    Text(L("asked: \(screen.requestedSizes)", "istenen: \(screen.requestedSizes)"))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            LinearGradient(colors: [Color(white: 0.16), Color(white: 0.06)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
    }

    // Green: everything we give goes through. Orange: iOS drops some of it.
    private var numberColor: Color {
        guard screen.isRunning, screen.sentFPS > 0 else { return .white.opacity(0.4) }
        return Double(screen.deliveredFPS) >= Double(screen.sentFPS) * 0.9 ? .green : .orange
    }
}

// While a video comes from Photos: downloaded if it is in iCloud, copied if it is big
private struct ImportRow: View {
    let progress: Progress

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L("Getting the video from the phone…", "Video telefondan alınıyor…"))
                    Spacer()
                    if progress.fractionCompleted > 0 {
                        Text("%\(Int(progress.fractionCompleted * 100))")
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
                if progress.fractionCompleted > 0 {
                    ProgressView(value: progress.fractionCompleted)
                }
            }
        }
    }
}

// Copies the picked video to the temporary folder
struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let target = FileManager.default.temporaryDirectory.appendingPathComponent(received.file.lastPathComponent)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: received.file, to: target)
            return MovieFile(url: target)
        }
    }
}
