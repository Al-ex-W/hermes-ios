import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The composer's "+" menu (the desktop's `context-menu.tsx`): photos, the camera and files to attach, a URL
/// reference, a pasted image and prompt snippets.
struct AttachMenu: View {
    @ObservedObject var composer: ComposerModel
    var disabled = false
    @State private var choosingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var takingPhoto = false
    @State private var choosingFiles = false
    @State private var askingURL = false
    @State private var url = ""
    @State private var showingSnippets = false

    var body: some View {
        Menu {
            Section("Attach") {
                Button { choosingPhotos = true } label: { Label("Photos…", systemImage: "photo.on.rectangle") }
                if AttachmentLoader.cameraAvailable {
                    Button { takingPhoto = true } label: { Label("Camera", systemImage: "camera") }
                }
                Button { choosingFiles = true } label: { Label("Files…", systemImage: "doc") }
                Button { pasteImage() } label: { Label("Paste image", systemImage: "doc.on.clipboard") }
                    .disabled(!UIPasteboard.general.hasImages)
                Button { askingURL = true } label: { Label("URL…", systemImage: "link") }
            }
            Button { showingSnippets = true } label: { Label("Prompt snippets…", systemImage: "text.bubble") }
        } label: {
            Image(systemName: Theme.Icon.attach)
                .font(.system(size: Theme.IconSize.sm, weight: .medium))
                .foregroundStyle(Theme.Text.tertiary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .disabled(disabled)
        .accessibilityLabel("Add attachments and tools")
        .photosPicker(isPresented: $choosingPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .images)
        .onChange(of: photoItems) {
            let items = photoItems
            photoItems = []
            Task { await addPhotos(items) }
        }
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { image in
                if let attachment = AttachmentLoader.photo(image, name: AttachmentLoader.photoName()) { composer.add(attachment) }
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result else { return }
            for url in urls {
                do {
                    composer.add(try AttachmentLoader.file(url))
                } catch {
                    composer.notice = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
        .alert("Attach a URL", isPresented: $askingURL) {
            TextField("https://example.com/post", text: $url)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Attach") {
                let link = url.trimmingCharacters(in: .whitespacesAndNewlines)
                url = ""
                if !link.isEmpty { composer.insert("@url:\(link) ") }
            }
            Button("Cancel", role: .cancel) { url = "" }
        } message: {
            Text("Hermes will fetch the page and include it as context for this turn.")
        }
        .confirmationDialog("Prompt snippets", isPresented: $showingSnippets, titleVisibility: .visible) {
            ForEach(PromptSnippet.all) { snippet in
                Button(snippet.label) { composer.insert(snippet.text) }
            }
        } message: {
            Text("Pick a starter prompt to drop into the composer.")
        }
    }

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let attachment = AttachmentLoader.photo(data: data, name: AttachmentLoader.photoName(index)) else {
                composer.notice = "Couldn't load a photo."
                continue
            }
            composer.add(attachment)
        }
    }

    private func pasteImage() {
        guard let image = UIPasteboard.general.image,
              let attachment = AttachmentLoader.photo(image, name: AttachmentLoader.photoName()) else { return }
        composer.add(attachment)
    }
}

/// A starter prompt from the "+" menu.
struct PromptSnippet: Identifiable {
    let id: String
    let label: String
    let text: String

    static let all = [
        PromptSnippet(id: "codeReview", label: "Code review", text: "Please review this for bugs, regressions, and missing tests."),
        PromptSnippet(id: "implementationPlan", label: "Implementation plan",
                      text: "Please make a concise implementation plan before changing code."),
        PromptSnippet(id: "explainThis", label: "Explain this", text: "Please explain how this works and point me to the key files."),
    ]
}

/// Turns what was picked into composer attachments.
enum AttachmentLoader {
    /// The longest side a photo is sent at.
    static let maxPhotoSide: CGFloat = 2048
    /// Hermes' image cap (`image.attach_bytes`, `file.attach`).
    static let maxBytes = 25 * 1024 * 1024
    /// Extensions `image.attach_bytes` accepts as they are.
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp"]

    /// The camera needs a usage description in Info.plist; without one it isn't offered.
    static var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
            && Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil
    }

    static func photoName(_ index: Int = 0) -> String {
        let stamp = Int(Date().timeIntervalSince1970)
        return index == 0 ? "photo-\(stamp).jpg" : "photo-\(stamp)-\(index + 1).jpg"
    }

    /// Photo library data (often HEIC) as a JPEG no larger than `maxPhotoSide`.
    static func photo(data: Data, name: String) -> ComposerAttachment? {
        guard let image = UIImage(data: data) else { return nil }
        return photo(image, name: name)
    }

    static func photo(_ image: UIImage, name: String) -> ComposerAttachment? {
        let scaled = downscaled(image, to: maxPhotoSide)
        guard let jpeg = scaled.jpegData(compressionQuality: 0.85) else { return nil }
        return ComposerAttachment(pending: .image(jpeg, filename: name), thumbnail: thumbnail(scaled))
    }

    /// A file from the document picker: an image Hermes takes as one goes in as a photo, anything else as a file.
    static func file(_ url: URL) throws -> ComposerAttachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard data.count <= maxBytes else {
            throw AttachmentError(message: "It is larger than \(maxBytes / 1024 / 1024) MB.")
        }
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        if imageExtensions.contains(ext), let image = UIImage(data: data) {
            return ComposerAttachment(pending: .image(data, filename: name), thumbnail: thumbnail(image))
        }
        if type?.conforms(to: .image) == true, let attachment = photo(data: data, name: (name as NSString).deletingPathExtension + ".jpg") {
            return attachment
        }
        return ComposerAttachment(pending: .file(data, filename: name, mime: type?.preferredMIMEType ?? "application/octet-stream"))
    }

    private static func downscaled(_ image: UIImage, to side: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > side else { return image }
        let scale = side / longest
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    private static func thumbnail(_ image: UIImage) -> Data? {
        downscaled(image, to: 160).jpegData(compressionQuality: 0.7)
    }
}

/// The system camera, for one photo.
struct CameraPicker: UIViewControllerRepresentable {
    let onPhoto: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onPhoto(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
