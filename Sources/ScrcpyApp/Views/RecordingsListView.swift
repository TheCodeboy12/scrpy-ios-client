import SwiftUI
import AVKit
import ScrcpyKit
#if canImport(Photos)
import Photos
#endif

public struct RecordingItem: Identifiable, Equatable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let date: Date
    public let sizeBytes: Int64
    public var duration: TimeInterval = 0

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    public var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    public var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

public struct RecordingsListView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var recordings: [RecordingItem] = []
    @State private var selectedVideoURL: URL?
    @State private var shareURL: URL?
    @State private var toastMessage: String?
    @State private var showDeleteConfirmation: Bool = false
    @State private var itemToDelete: RecordingItem?

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

                if recordings.isEmpty {
                    emptyStateView
                } else {
                    List {
                        Section {
                            ForEach(recordings) { item in
                                recordingRow(item)
                            }
                            .onDelete(perform: deleteRows)
                        } header: {
                            Text("Saved in Files: On My iPhone > Scrcpy")
                        }
                    }
                    .listStyle(.insetGrouped)
                }

                // Toast Notification Overlay
                if let message = toastMessage {
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text(message)
                                .font(.subheadline.bold())
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .cornerRadius(20)
                        .shadow(radius: 5)
                        .padding(.bottom, 20)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(10)
                }
            }
            .navigationTitle("Recordings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !recordings.isEmpty {
                        EditButton()
                    }
                }
            }
            .onAppear {
                loadRecordings()
            }
            .sheet(item: $selectedVideoURL) { url in
                VideoPlayerSheet(url: url)
            }
            .sheet(item: $shareURL) { url in
                ActivityViewWrapper(activityItems: [url])
            }
            .alert("Delete Recording?", isPresented: $showDeleteConfirmation, presenting: itemToDelete) { item in
                Button("Delete", role: .destructive) {
                    deleteItem(item)
                }
                Button("Cancel", role: .cancel) {}
            } message: { item in
                Text("Are you sure you want to delete '\(item.name)'?")
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.badge.plus")
                .font(.system(size: 64))
                .foregroundColor(.secondary)

            Text("No Recordings Yet")
                .font(.title3.bold())

            Text("Connect to your Android camera or screen, then tap the Record button in the controls to capture live lossless video.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 8) {
                Label("Direct pass-through H.264 / H.265", systemImage: "bolt.fill")
                Label("0% extra CPU/GPU re-encoding", systemImage: "cpu")
                Label("Accessible in native iOS Files app", systemImage: "folder.fill")
                Label("Save directly to Photos Camera Roll", systemImage: "photo.on.rectangle")
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.top, 8)
        }
        .padding()
    }

    private func recordingRow(_ item: RecordingItem) -> some View {
        HStack(spacing: 14) {
            // Play icon thumbnail
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .frame(width: 50, height: 50)
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundColor(.blue)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.subheadline.bold())
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(item.formattedDate)
                    Text("•")
                    Text(item.formattedSize)
                    if item.duration > 0 {
                        Text("•")
                        Text(item.formattedDuration)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            // Quick Actions Menu
            Menu {
                Button(action: { selectedVideoURL = item.url }) {
                    Label("Play Video", systemImage: "play.fill")
                }

                #if canImport(Photos)
                Button(action: { saveToPhotos(item: item) }) {
                    Label("Save to Photos", systemImage: "photo")
                }
                #endif

                Button(action: { shareURL = item.url }) {
                    Label("Share / Export", systemImage: "square.and.arrow.up")
                }

                Divider()

                Button(role: .destructive, action: {
                    itemToDelete = item
                    showDeleteConfirmation = true
                }) {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .frame(width: 32, height: 32)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedVideoURL = item.url
        }
    }

    private func loadRecordings() {
        let dir = StreamRecorder.recordingsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey], options: .skipsHiddenFiles) else {
            recordings = []
            return
        }

        var items: [RecordingItem] = []
        for file in files where file.pathExtension.lowercased() == "mp4" || file.pathExtension.lowercased() == "mov" {
            let resourceValues = try? file.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
            let size = Int64(resourceValues?.fileSize ?? 0)
            let date = resourceValues?.creationDate ?? Date()

            // Asynchronously resolve asset duration
            let asset = AVURLAsset(url: file)
            let durationSec = CMTimeGetSeconds(asset.duration)
            let validDuration = durationSec.isFinite ? durationSec : 0

            items.append(RecordingItem(
                url: file,
                name: file.lastPathComponent,
                date: date,
                sizeBytes: size,
                duration: validDuration
            ))
        }

        // Sort by newest first
        recordings = items.sorted { $0.date > $1.date }
    }

    private func deleteRows(at offsets: IndexSet) {
        for index in offsets {
            let item = recordings[index]
            try? FileManager.default.removeItem(at: item.url)
        }
        recordings.remove(atOffsets: offsets)
    }

    private func deleteItem(_ item: RecordingItem) {
        try? FileManager.default.removeItem(at: item.url)
        if let idx = recordings.firstIndex(where: { $0.id == item.id }) {
            recordings.remove(at: idx)
        }
    }

    #if canImport(Photos)
    private func saveToPhotos(item: RecordingItem) {
        Task {
            do {
                try await StreamRecorder.saveToPhotos(fileURL: item.url)
                showToast("Saved to Photos Camera Roll!")
            } catch {
                showToast("Photo Save Failed: \(error.localizedDescription)")
            }
        }
    }
    #endif

    private func showToast(_ message: String) {
        withAnimation {
            toastMessage = message
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run {
                withAnimation {
                    if self.toastMessage == message {
                        self.toastMessage = nil
                    }
                }
            }
        }
    }
}

// MARK: - Video Player Sheet
private struct VideoPlayerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL

    var body: some View {
        NavigationStack {
            VideoPlayer(player: AVPlayer(url: url))
                .ignoresSafeArea()
                .navigationTitle(url.lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
        }
    }
}

// MARK: - Activity View Wrapper (Share Sheet)
private struct ActivityViewWrapper: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
