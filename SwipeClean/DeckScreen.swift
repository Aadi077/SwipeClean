import Photos
import SwiftUI
import UIKit

@MainActor
struct DeckScreen: View {
    @Environment(PhotoDeck.self) private var deck
    @Environment(\.displayScale) private var displayScale

    @State private var offset: CGSize = .zero
    @State private var locked = false
    @State private var showTrash = false
    @State private var fitMode = false
    @State private var cardPixels = CGSize(width: 900, height: 1400)

    private let threshold: CGFloat = 110

    var body: some View {
        VStack(spacing: 0) {
            header
            cards
            controls
        }
        .sheet(isPresented: $showTrash) { TrashView() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(deck.remaining)")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text(deck.remaining == 1 ? "photo left" : "photos left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                trashChip
                menu
            }

            ProgressView(value: deck.sessionProgress)
                .tint(Color.keepGreen)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .animation(.snappy, value: deck.remaining)
    }

    private var trashChip: some View {
        Button { showTrash = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "trash.fill")
                Text("\(deck.pending.count)")
                    .contentTransition(.numericText())
                if deck.pendingBytes > 0 {
                    Text(Fmt.bytes(deck.pendingBytes))
                        .opacity(0.75)
                }
            }
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(deck.pending.isEmpty ? Color.secondary : Color.deleteRed)
            .background(
                Capsule().fill(Color.deleteRed.opacity(deck.pending.isEmpty ? 0.08 : 0.20))
            )
        }
        .buttonStyle(.plain)
        .disabled(deck.pending.isEmpty)
    }

    private var menu: some View {
        Menu {
            Picker("Order", selection: sortBinding) {
                ForEach(SortOrder.allCases) { order in
                    Label(order.label, systemImage: order.symbol).tag(order)
                }
            }
            Button {
                withAnimation(.snappy) { fitMode.toggle() }
            } label: {
                Label(fitMode ? "Fill the card" : "Fit the whole photo",
                      systemImage: fitMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            Divider()
            Button {
                Task { await deck.reload() }
            } label: {
                Label("Rescan library", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) {
                Task { await deck.resetProgress() }
            } label: {
                Label("Start over", systemImage: "arrow.counterclockwise")
            }
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
        }
    }

    private var sortBinding: Binding<SortOrder> {
        Binding(get: { deck.sortOrder }, set: { deck.setSort($0) })
    }

    // MARK: - Card stack

    private var cards: some View {
        GeometryReader { geo in
            let size = CGSize(width: geo.size.width - 36, height: geo.size.height - 16)
            ZStack {
                if let current = deck.current {
                    ForEach(Array(deck.upcoming.enumerated()).reversed(), id: \.element.localIdentifier) { depth, asset in
                        CardFrame(asset: asset, size: size, fit: fitMode)
                            .scaleEffect(1 - CGFloat(depth + 1) * 0.045)
                            .offset(y: CGFloat(depth + 1) * 14)
                            .opacity(0.85)
                            .allowsHitTesting(false)
                    }

                    CardFrame(asset: current, size: size, fit: fitMode)
                        .overlay { stamps }
                        .offset(offset)
                        .rotationEffect(.degrees(Double(offset.width) / 20), anchor: .bottom)
                        .gesture(drag)
                        .onTapGesture { withAnimation(.snappy) { fitMode.toggle() } }
                        .id(current.localIdentifier)
                } else {
                    DoneCard(showTrash: $showTrash)
                        .frame(width: size.width, height: size.height)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear {
                cardPixels = CGSize(width: size.width * displayScale, height: size.height * displayScale)
                prefetch()
            }
            .onChange(of: deck.cursor) { prefetch() }
        }
    }

    private var stamps: some View {
        ZStack {
            stamp(text: "KEEP", color: .keepGreen, angle: -14)
                .opacity(Double(max(0, offset.width) / threshold))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            stamp(text: "DELETE", color: .deleteRed, angle: 14)
                .opacity(Double(max(0, -offset.width) / threshold))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .padding(22)
        .allowsHitTesting(false)
    }

    private func stamp(text: String, color: Color, angle: Double) -> some View {
        Text(text)
            .font(.system(size: 30, weight: .heavy, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(color, lineWidth: 4)
            }
            .rotationEffect(.degrees(angle))
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 26) {
            roundButton(symbol: "trash.fill", color: .deleteRed, diameter: 66) {
                fling(delete: true)
            }
            .disabled(deck.current == nil || locked)

            roundButton(symbol: "arrow.uturn.backward", color: .white.opacity(0.55), diameter: 50, action: undo)
                .disabled(!deck.canUndo || locked)
                .opacity(deck.canUndo ? 1 : 0.3)

            roundButton(symbol: "checkmark", color: .keepGreen, diameter: 66) {
                fling(delete: false)
            }
            .disabled(deck.current == nil || locked)
        }
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private func roundButton(symbol: String, color: Color, diameter: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: diameter * 0.36, weight: .bold))
                .foregroundStyle(color)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(Color.cardSurface))
                .overlay(Circle().strokeBorder(color.opacity(0.35), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.45), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Gestures

    private var drag: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard !locked else { return }
                offset = value.translation
            }
            .onEnded { value in
                guard !locked else { return }
                let projected = value.translation.width + value.predictedEndTranslation.width * 0.35
                if projected > threshold {
                    fling(delete: false)
                } else if projected < -threshold {
                    fling(delete: true)
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { offset = .zero }
                }
            }
    }

    private func fling(delete: Bool) {
        guard !locked, deck.current != nil else { return }
        locked = true
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()

        withAnimation(.easeOut(duration: 0.26)) {
            offset = CGSize(width: delete ? -800 : 800, height: offset.height + 60)
        }

        Task {
            try? await Task.sleep(nanoseconds: 260_000_000)
            deck.decide(delete: delete)
            offset = .zero
            locked = false
        }
    }

    private func undo() {
        guard deck.canUndo else { return }
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        offset = .zero
        deck.undo()
    }

    private func prefetch() {
        ImageStore.shared.prefetch(deck.window(ahead: 10), size: cardPixels)
    }
}

@MainActor
struct DoneCard: View {
    @Environment(PhotoDeck.self) private var deck
    @Binding var showTrash: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.keepGreen)
            Text("All caught up")
                .font(.title2.bold())
            Text(deck.pending.isEmpty
                 ? "You've been through every photo in your library."
                 : "\(deck.pending.count) item\(deck.pending.count == 1 ? "" : "s") still waiting in the bin.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 28)

            if !deck.pending.isEmpty {
                Button("Review and delete") { showTrash = true }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.deleteRed)
            }
            Button("Start over") { Task { await deck.resetProgress() } }
                .buttonStyle(.bordered)
                .tint(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.cardSurface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}
