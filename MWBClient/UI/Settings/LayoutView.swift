import SwiftUI

struct LayoutView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                VStack(spacing: 24) {
                    screenDiagram

                    Text("Where is your Windows machine relative to this Mac?")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Screen Layout")
        .onChange(of: settings.crossingEdge) {
            coordinator.crossingEdgeDidChange()
        }
    }

    // MARK: - Screen Diagram

    private var screenDiagram: some View {
        ZStack {
            // Mac screen rectangle
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 2)
                .fill(Color.primary.opacity(0.05))
                .frame(width: 200, height: 140)

            Text("Mac")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Edge buttons
            edgeButton(for: .top)
                .offset(y: -90)

            edgeButton(for: .bottom)
                .offset(y: 90)

            edgeButton(for: .left)
                .offset(x: -120)

            edgeButton(for: .right)
                .offset(x: 120)
        }
    }

    private func edgeButton(for edge: CrossingEdge) -> some View {
        let isSelected = settings.crossingEdge == edge
        let label: String
        let rotation: Angle

        switch edge {
        case .top:
            label = "Windows"
            rotation = .zero
        case .bottom:
            label = "Windows"
            rotation = .zero
        case .left:
            label = "Win"
            rotation = .degrees(-90)
        case .right:
            label = "Win"
            rotation = .degrees(90)
        }

        return Button {
            settings.crossingEdge = edge
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.forward")
                    .font(.caption2)
                    .rotationEffect(rotation)
                Text(label)
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1.5)
            )
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}
