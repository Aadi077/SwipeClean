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
    @State private var showFilters = false
    @State private var fitMode = false
    @State private var videoPaused = false
    @State private var cardPixels = CGSize(width: 900, height: 1400)

    private let threshold: CGFloat = 110

    var body: some View {
        VStack(spacing: 0) {
            header
            cards
            controls
        }
        .sheet(isPresented: $showTrash) { TrashView() }
        .sheet(isPresented: $showFilters) { FilterPickerView() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(deck.remaining)")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Spacer(minLength: 8)
                monthButton
                trashChip
                menu
            }

            ProgressView(value: deck.sessionProgress)
                .tint(Color.keepGreen)

            if let sizing = deck.sizingProgress {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text("Measuring sizes — \(sizing.done) of \(sizing.total)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .animation(.snappy, value: deck.remaining)
    }

    private var subtitle: String {
        let noun = deck.remaining == 1 ? "photo" : "photos"
        guard let summary = deck.filterSummary else { return "\(noun) left" }
        return "\(noun) left in \(summary)"
    }

    private var monthButton: some View {
        Button { showFilters = true } label: {
            Image(systemName: deck.isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(deck.isFiltered ? Color.keepGreen : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
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
            Toggle(isOn: Binding(
                get: { deck.allowsCellular },
                set: { deck.setAllowsCellular($0) }
            )) {
                Label("Use cellular data", systemImage: "antenna.radiowaves.left.and.right")
            }
            Divider()
            Button { showFilters = true } label: {
                Label("Filter photos", systemImage: "line.3.horizontal.decrease.circle")
            }
            Button {
                Task { await deck.reload() }
            } label: {
                Label("Rescan library", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) {
                Task { await deck.resetProgress() }
            } label: {
                Label(deck.filterSummary.map { "Start over in \($0)" } ?? "Start over",
                      systemImage: "arrow.counterclockwise")
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

                    CardFrame(asset: current, size: size, fit: fitMode, paused: videoPaused)
                        .overlay { stamps }
                        .offset(offset)
                        .rotationEffect(.degrees(Double(offset.width) / 20), anchor: .bottom)
                        .gesture(drag)
                        .onTapGesture {
                            // Tap means different things by type: pause a video,
                            // reframe a photo.
                            if current.mediaType == .video {
                                videoPaused.toggle()
                            } else {
                                withAnimation(.snappy) { fitMode.toggle() }
                            }
                        }
                        .id(current.localIdentifier)
                } else {
                    DoneCard(showTrash: $showTrash, showFilters: $showFilters)
                        .frame(width: size.width, height: size.height)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear {
                cardPixels = CGSize(width: size.width * displayScale, height: size.height * displayScale)
                prefetch()
            }
            .onChange(of: deck.cursor) {
                prefetch()
                videoPaused = false
            }
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
            stamp(text: "SKIP", color: .skipGrey, angle: 0)
                .opacity(Double(max(0, -offset.height) / threshold))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 54)
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
        HStack(spacing: 18) {
            roundButton(symbol: "trash.fill", color: .deleteRed, diameter: 66) {
                commit(.bin)
            }
            .disabled(deck.current == nil || locked)

            roundButton(symbol: "arrow.uturn.backward", color: .white.opacity(0.55), diameter: 46, action: undo)
                .disabled(!deck.canUndo || locked)
                .opacity(deck.canUndo ? 1 : 0.3)

            roundButton(symbol: "arrow.up", color: .skipGrey, diameter: 46) {
                commit(.skip)
            }
            .disabled(deck.current == nil || locked)

            roundButton(symbol: "checkmark", color: .keepGreen, diameter: 66) {
                commit(.keep)
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
                let across = value.translation.width + value.predictedEndTranslation.width * 0.35
                let up = value.translation.height + value.predictedEndTranslation.height * 0.35

                // Upward only wins when it clearly dominates, so a normal
                // left/right flick that drifts a little never reads as a skip.
                if up < -threshold, abs(up) > abs(across) {
                    commit(.skip)
                } else if across > threshold {
                    commit(.keep)
                } else if across < -threshold {
                    commit(.bin)
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { offset = .zero }
                }
            }
    }

    private func commit(_ verdict: PhotoDeck.Verdict) {
        guard !locked, deck.current != nil else { return }
        locked = true
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()

        let target: CGSize
        switch verdict {
        case .keep: target = CGSize(width: 800, height: offset.height + 60)
        case .bin: target = CGSize(width: -800, height: offset.height + 60)
        case .skip: target = CGSize(width: offset.width, height: -1000)
        }

        withAnimation(.easeOut(duration: 0.26)) { offset = target }

        Task {
            try? await Task.sleep(nanoseconds: 260_000_000)
            switch verdict {
            case .keep: deck.decide(delete: false)
            case .bin: deck.decide(delete: true)
            case .skip: deck.skip()
            }
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
    @Binding var showFilters: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.keepGreen)
            Text("All caught up")
                .font(.title2.bold())
            Text(doneMessage)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 28)

            if !deck.pending.isEmpty {
                Button("Review and delete") { showTrash = true }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.deleteRed)
            }
            if deck.skippedCount > 0 && !deck.filter.skippedOnly {
                Button("Review \(deck.skippedCount) skipped") { deck.toggleSkippedOnly() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.skipGrey)
            }

            Button(deck.isFiltered ? "Change filter" : "Filter photos") {
                showFilters = true
            }
            .buttonStyle(.bordered)
            .tint(.white)

            Button(deck.filterSummary.map { "Start over in \($0)" } ?? "Start over") {
                Task { await deck.resetProgress() }
            }
            .buttonStyle(.borderless)
            .tint(.secondary)
            .font(.footnote)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.cardSurface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var doneMessage: String {
        if !deck.pending.isEmpty {
            let noun = deck.pending.count == 1 ? "item" : "items"
            return "\(deck.pending.count) \(noun) still waiting in the bin."
        }
        guard let summary = deck.filterSummary else {
            return "You've been through every photo in your library."
        }
        return "You've been through every photo in \(summary)."
    }
}
