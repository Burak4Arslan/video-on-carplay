import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct CarPlayView: View {
    @ObservedObject var screen: CarScreen
    @State private var pickedVideo: PhotosPickerItem?
    // While a video is coming from Photos (it may download from iCloud; big files take a while)
    @State private var importProgress: Progress?
    @State private var link = ""
    @State private var loadingLink = false
    @State private var showLog = false
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
                     ? L("iOS collects artwork changes and passes them on every half second; skipping the wait sends every frame right away. Try the second setting in the car to see what CarPlay prefers.",
                         "iOS kapak değişikliklerini biriktirip yarım saniyede bir iletiyor; bekleme atlanınca her kare hemen gider. İkinci ayarın CarPlay'e etkisini arabada dene.")
                     : L("No way to skip the wait was found on this iOS version; iOS passes on about 2 frames per second.",
                         "Bu iOS sürümünde beklemeyi atlamanın yolu bulunamadı; iOS saniyede yaklaşık 2 kare iletir."))
            }

            Section(L("Picture", "Görüntü")) {
                Picker(L("Source", "Kaynak"), selection: $screen.source) {
                    ForEach(CarScreen.Source.allCases) { Text($0.shortName).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker(selection: $screen.fps) {
                    ForEach(CarScreen.fpsChoices, id: \.self) { Text(L("\(Int($0)) fps", "\(Int($0)) kare/sn")).tag($0) }
                } label: {
                    Label(L("Speed", "Hız"), systemImage: "speedometer")
                }
            }

            videoSection

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
        .id(language)
        .navigationTitle("Video on CarPlay")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker(L("Language", "Dil"), selection: $language) {
                        ForEach(AppLanguage.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                } label: {
                    Image(systemName: "globe")
                }
                .accessibilityLabel(L("Language", "Dil"))
            }
        }
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

    private var videoSection: some View {
        Section {
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
            } else if let status = screen.videoStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }

            // .current: take the video as it is. By default Photos may convert it to a compatible format, which takes long.
            PhotosPicker(selection: $pickedVideo, matching: .videos, preferredItemEncoding: .current) {
                Label(L("Pick a video from Photos", "Fotoğraflar'dan video seç"), systemImage: "photo.on.rectangle")
            }
            .disabled(importProgress != nil)

            HStack {
                Image(systemName: "link").foregroundStyle(.secondary)
                TextField(L("YouTube, mp4 or m3u8 link", "YouTube, mp4 ya da m3u8 linki"), text: $link)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit(openLink)
                if loadingLink {
                    ProgressView()
                } else {
                    Button(L("Open", "Aç"), action: openLink)
                        .buttonStyle(.bordered)
                        .disabled(link.isEmpty)
                }
            }

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
            Text(L("Video (with sound)", "Video (sesiyle)"))
        } footer: {
            Text(screen.method == .frames
                 ? L("The sound comes from the car's speakers, the picture from the artwork.", "Ses arabanın hoparlöründen, görüntü kapak resminden gelir.")
                 : L("Animated artwork (iOS 26): the system plays a 2-minute clip cut from the video by itself. Supported kinds: \(screen.animatedSupport).",
                     "Hareketli kapak (iOS 26): videodan kırpılmış 2 dakikalık bir klibi sistem kendisi oynatır. Desteklenen türler: \(screen.animatedSupport)."))
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

    private func openLink() {
        guard !link.isEmpty, !loadingLink else { return }
        loadingLink = true
        Task {
            await screen.loadLink(link)
            loadingLink = false
        }
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
