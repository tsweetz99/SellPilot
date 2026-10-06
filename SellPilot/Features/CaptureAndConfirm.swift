import SwiftUI
import PhotosUI
import AVFoundation
struct CaptureView: View {
    @Bindable var workflow: SellingWorkflow
    @State private var selections: [PhotosPickerItem] = []
    @State private var camera = false
    @State private var importing = false
    var body: some View { VStack(alignment: .leading, spacing: 18) {
        Text("What are you selling?").font(.largeTitle.bold())
        Text("Start with a few clear photos. Front, back, label, accessories, and any wear.").foregroundStyle(.secondary)
        HStack {
            PhotosPicker(selection: $selections, maxSelectionCount: max(1, 10 - workflow.item.photos.count), matching: .images) { Label(importing ? "Importing…" : "Photo library", systemImage: "photo.on.rectangle").padding(14) }.disabled(workflow.item.photos.count >= 10 || importing)
            Button { Task { if UIImagePickerController.isSourceTypeAvailable(.camera) { let allowed = await AVCaptureDevice.requestAccess(for: .video); if allowed { camera = true } else { workflow.error = "Enable camera access in Settings, or import from your library." } } else { workflow.error = "Camera unavailable on this device. Use the photo library or demo photo." } } } label: { Label("Camera", systemImage: "camera").padding(14) }.disabled(workflow.item.photos.count >= 10)
        }.buttonStyle(.bordered)
        Text("\(workflow.item.photos.count)/10 photos · \(workflow.item.photos.count >= 3 ? "I have enough photos to analyze this item." : "You can analyze with any photo count.")").font(.caption).foregroundStyle(PilotTheme.accent)
        ForEach(Array(workflow.item.photos.enumerated()), id: \.element.id) { index, photo in PilotCard {
            PhotoView(photo: photo, original: true)
            HStack {
                Button { workflow.item.coverPhotoID = photo.id } label: { Label(workflow.item.coverPhotoID == photo.id ? "Cover" : "Make cover", systemImage: workflow.item.coverPhotoID == photo.id ? "star.fill" : "star") }
                Spacer()
                Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0).accessibilityLabel("Move photo earlier")
                Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }.disabled(index == workflow.item.photos.count - 1).accessibilityLabel("Move photo later")
                Button(role: .destructive) { workflow.item.photos.removeAll { $0.id == photo.id }; if workflow.item.coverPhotoID == photo.id { workflow.item.coverPhotoID = workflow.item.photos.first?.id } } label: { Image(systemName: "trash") }.accessibilityLabel("Delete photo")
            }.buttonStyle(.bordered)
        } }
        if workflow.item.photos.isEmpty { Button("Try with a labeled demo photo") { add(PhotoImport.demoPhoto()) }.accessibilityIdentifier("demoPhoto"); Text(workflow.services.identification.disclosure ?? "Demo mode: identification always returns a sample tool; edit it to match your item.").font(.caption).foregroundStyle(.secondary) }
        if !workflow.item.photos.isEmpty, let disclosure = workflow.services.identification.disclosure { Text(disclosure).font(.caption).foregroundStyle(.secondary) }
    }.sheet(isPresented: $camera) { CameraPicker(onImage: add) }
        .onChange(of: selections) { _, selected in Task { importing = true; defer { importing = false; selections = [] }; for selection in selected { do { if let data = try await selection.loadTransferable(type: Data.self) { add(data) } else { workflow.error = "One photo could not be imported." } } catch { workflow.error = error.localizedDescription } } } }
    }
    private func add(_ data: Data) {
        guard workflow.item.photos.count < 10 else { return }
        guard let normalized = PhotoImport.normalized(data) else { workflow.error = "Unsupported image. Choose another photo."; return }
        let used = workflow.item.photos.reduce(0) { $0 + $1.originalByteCount }
        guard used + data.count <= 100_000_000 else { workflow.error = "This item has reached the 100 MB photo limit. Choose smaller photos or remove one."; return }
        do {
            let photo = try SellItemPhoto(originalData: data, previewData: normalized)
            workflow.item.photos.append(photo)
            if workflow.item.coverPhotoID == nil { workflow.item.coverPhotoID = photo.id }
            workflow.save()
        } catch { workflow.error = "Could not save this photo on your device: \(error.localizedDescription)" }
    }
    private func move(_ index: Int, by offset: Int) { workflow.item.photos.swapAt(index, index + offset) }
}
struct IdentificationView: View {
    @Bindable var workflow: SellingWorkflow
    private let categories = SellItem.categories
    var body: some View { VStack(alignment: .leading, spacing: 16) {
        Text("Is this right?").font(.largeTitle.bold())
        if let photo = workflow.item.orderedPhotos.first { PhotoView(photo: photo) }
        PilotCard {
            Text("\(workflow.item.identification?.isSimulated == false ? "AI confidence" : "Simulated AI confidence"): \(Int(workflow.item.confidenceScore * 100))%").font(.headline)
            Text(workflow.item.confidenceScore < 0.7 ? "Low confidence. Review possible matches and verify every detail." : (workflow.item.identification?.isSimulated == false ? "AI suggestions can be wrong. Verify every detail, especially the model number." : "This is a demo match, not real image recognition. Verify every detail.")).font(.caption).foregroundStyle(.secondary)
            if let identification = workflow.item.identification { Text("Possible model: \(identification.possibleModelNumber ?? "Unknown")").font(.caption); ForEach(identification.recognizedAttributes.keys.sorted(), id: \.self) { key in Text("\(key): \(identification.recognizedAttributes[key] ?? "")").font(.caption) } }
        }
        PilotCard {
            TextField("Product name", text: $workflow.item.title).accessibilityIdentifier("productTitle")
            Divider(); TextField("Brand", text: $workflow.item.brand); Divider(); TextField("Model", text: $workflow.item.model)
            Picker("Category", selection: $workflow.item.category) { ForEach(categories, id: \.self) { Text($0).tag($0) } }
            TextField("Subcategory", text: $workflow.item.subcategory); TextField("Color", text: $workflow.item.color)
            Picker("Condition", selection: $workflow.item.condition) { ForEach(ItemCondition.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
        }
        Text("Other possible matches").font(.headline)
        ForEach(workflow.item.identification?.alternateMatches ?? []) { match in Button { workflow.apply(match) } label: { HStack { Text(match.title); Spacer(); Image(systemName: "arrow.up.left") }.padding(14) }.buttonStyle(.bordered) }
    } }
}
struct NotesView: View {
    @Bindable var workflow: SellingWorkflow
    @State private var dictation = DictationController()
    @State private var starting = false
    @State private var initialNote = ""
    var body: some View { VStack(alignment: .leading, spacing: 18) {
        Text("Anything the photos don’t show?").font(.largeTitle.bold())
        Text("Does it work? Any missing accessories, defects, or useful history?").foregroundStyle(.secondary)
        PilotCard { TextEditor(text: $workflow.item.sellerNotes).frame(minHeight: 140).accessibilityLabel("Seller note"); Text("Example: Works well. Battery not included. Small scratch on the handle.").font(.caption).foregroundStyle(.secondary) }
        Button { if dictation.recording { dictation.stop() } else { initialNote = workflow.item.sellerNotes; starting = true; Task { await dictation.start(); starting = false } } } label: { Label(starting ? "Starting…" : dictation.recording ? "Stop dictation" : "Dictate a note", systemImage: dictation.recording ? "stop.circle.fill" : "mic.fill").padding(12) }.buttonStyle(.bordered).disabled(starting)
        TextField("Condition notes (optional)", text: $workflow.item.conditionNotes, axis: .vertical).textFieldStyle(.roundedBorder)
        if let error = dictation.error { Text(error).font(.caption).foregroundStyle(.red) }
    }.onChange(of: dictation.transcript) { _, transcript in workflow.item.sellerNotes = [initialNote, transcript].filter { !$0.isEmpty }.joined(separator: "\n") }.onDisappear { dictation.stop() } }
}
