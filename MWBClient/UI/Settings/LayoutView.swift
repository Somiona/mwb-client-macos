import SwiftUI
import UniformTypeIdentifiers

struct LayoutView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppCoordinator.self) private var coordinator

    // Local state for the drag & drop array
    @State private var machineSlots: [String] = ["", "", "", ""]
    // State to track if drag is happening to update UI accordingly if needed
    @State private var draggedItem: String?

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                VStack(spacing: 24) {
                    matrixGrid
                        .padding(.vertical)

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Devices in a single row", isOn: Binding(
                            get: { settings.matrixOneRow },
                            set: { 
                                settings.matrixOneRow = $0 
                                broadcastMatrix() 
                            }
                        ))
                        Text("Sets whether the devices are aligned on a single row. A two by two matrix is considered otherwise")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Wrap mouse", isOn: Binding(
                            get: { settings.matrixCircle },
                            set: { 
                                settings.matrixCircle = $0 
                                broadcastMatrix() 
                            }
                        ))
                        Text("Move the mouse back to the first machine when it passes the last one")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            } header: {
                Text("Device Arrangement")
            } footer: {
                Text("Drag and drop screens to match your physical layout.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Screen Layout")
        .onAppear {
            loadMatrix()
        }
        .onChange(of: settings.machineMatrixString) {
            loadMatrix()
        }
    }

    private var matrixGrid: some View {
        let columns = settings.matrixOneRow 
            ? Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)
            : Array(repeating: GridItem(.flexible(), spacing: 12), count: 2)

        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(0..<4, id: \.self) { index in
                MachineSlotView(name: machineSlots[index], index: index)
                    .onDrag {
                        self.draggedItem = String(index)
                        return NSItemProvider(object: String(index) as NSString)
                    }
                    .onDrop(of: [.text], isTargeted: nil) { providers in
                        guard let provider = providers.first else { return false }
                        let _ = provider.loadObject(ofClass: NSString.self) { item, _ in
                            if let str = item as? String, let fromIndex = Int(str) {
                                DispatchQueue.main.async {
                                    swapSlots(from: fromIndex, to: index)
                                }
                            }
                        }
                        return true
                    }
            }
        }
        .frame(maxWidth: settings.matrixOneRow ? 500 : 250)
    }

    private func loadMatrix() {
        let parts = settings.machineMatrixString.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        var newSlots = ["", "", "", ""]
        for i in 0..<min(4, parts.count) {
            newSlots[i] = parts[i].trimmingCharacters(in: .whitespaces)
        }
        // Always place current machine in slot 1 if it's completely empty? No, respect settings.
        machineSlots = newSlots
    }

    private func swapSlots(from: Int, to: Int) {
        guard from != to else { return }
        machineSlots.swapAt(from, to)
        
        // Save to settings
        settings.machineMatrixString = machineSlots.joined(separator: ",")
        
        // Broadcast change
        broadcastMatrix()
    }

    private func broadcastMatrix() {
        Task {
            await coordinator.broadcastMatrix(slots: machineSlots, oneRow: settings.matrixOneRow, circle: settings.matrixCircle)
        }
    }
}

struct MachineSlotView: View {
    let name: String
    let index: Int
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(name.isEmpty ? Color.secondary.opacity(0.1) : Color.accentColor.opacity(0.2))
                .strokeBorder(name.isEmpty ? Color.secondary.opacity(0.3) : Color.accentColor, lineWidth: 2)
                
            if name.isEmpty {
                Text("Empty")
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else {
                Text(name)
                    .foregroundColor(.primary)
                    .font(.headline)
            }
        }
        .frame(height: 80)
        // Add content shape so the empty area is draggable/droppable
        .contentShape(Rectangle())
    }
}
