import SwiftUI
import UIKit

struct ReleaseNoteView: View {
    let note: ReleaseNote
    let close: () -> Void
    @State private var logoGlintTrigger = 0
    @State private var versionGlintTrigger = 0
    @State private var isFeatureContainerVisible = false
    @State private var visibleFeatureCount = 0
    @State private var isConfirmEnabled = false
    @State private var confirmAuraPhase = Angle.zero
    @State private var entranceTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack {
                background
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header
                        featureSection
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .padding(.bottom, 104)
                }
                .scrollIndicators(.hidden)
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .toolbar(.hidden, for: .navigationBar)
        }
        .onAppear { startEntranceEffectsAfterSheetSettles() }
        .onDisappear {
            entranceTask?.cancel()
            entranceTask = nil
        }
    }

    private var background: some View {
        ZStack(alignment: .topLeading) {
            Color(.systemGroupedBackground)
            LinearGradient(
                colors: [
                    BatonReleaseNoteColors.primary.opacity(0.10),
                    BatonReleaseNoteColors.secondary.opacity(0.06),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(height: 260)
            .blur(radius: 18)
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .shadow(color: Color.black.opacity(0.10), radius: 12, x: 0, y: 6)
                    .frame(width: 80, height: 80)
                    .overlay {
                        BatonReleaseNoteGlintEffectView(
                            trigger: logoGlintTrigger,
                            lastTrigger: 0,
                            duration: BatonReleaseNoteEntranceTiming.logoGlintDuration,
                            startDelay: 0
                        )
                        .mask(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    }
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭更新说明")
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Baton 已更新")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    versionBadge
                }
                Text("感谢使用 Baton，这里是本次更新的重点。")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var versionBadge: some View {
        Text("v\(note.version)")
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(BatonReleaseNoteColors.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule(style: .continuous).fill(BatonReleaseNoteColors.primary.opacity(0.12)))
            .overlay {
                BatonReleaseNoteGlintEffectView(
                    trigger: versionGlintTrigger,
                    lastTrigger: 0,
                    duration: BatonReleaseNoteEntranceTiming.versionGlintDuration,
                    startDelay: 0
                )
                .mask(Capsule(style: .continuous))
            }
    }

    private var featureSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                ForEach(Array(note.features.prefix(visibleFeatureCount).enumerated()), id: \.element.id) { index, feature in
                    BatonReleaseNoteFeatureItemRow(index: index, feature: feature)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    if index < visibleFeatureCount - 1 {
                        Divider()
                            .padding(.leading, 60)
                            .transition(.opacity)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground).opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .opacity(isFeatureContainerVisible ? 1 : 0)
            .offset(y: isFeatureContainerVisible ? 0 : 8)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.55)
            confirmButton
                .padding(.horizontal, 24)
                .padding(.top, 14)
                .padding(.bottom, 12)
        }
        .background(.ultraThinMaterial)
    }

    private var confirmButton: some View {
        Button {
            guard isConfirmEnabled else { return }
            BatonReleaseNoteHaptics.success()
            close()
        } label: {
            Text("我知道了")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(.white.opacity(isConfirmEnabled ? 1 : 0.72))
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isConfirmEnabled ? BatonReleaseNoteColors.primary : Color.secondary.opacity(0.28))
                )
                .overlay { BatonReleaseNoteConfirmButtonAura(phase: confirmAuraPhase, isActive: isConfirmEnabled) }
                .shadow(color: isConfirmEnabled ? BatonReleaseNoteColors.primary.opacity(0.24) : .clear, radius: 10, y: 5)
                .scaleEffect(isConfirmEnabled ? 1 : 0.985)
        }
        .buttonStyle(.plain)
        .disabled(!isConfirmEnabled)
        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: isConfirmEnabled)
        .onChange(of: isConfirmEnabled) { _, newValue in
            guard newValue else {
                confirmAuraPhase = .zero
                return
            }
            withAnimation(.linear(duration: 5.4).repeatForever(autoreverses: false)) {
                confirmAuraPhase = .degrees(360)
            }
        }
    }

    private func revealFeatures() async {
        visibleFeatureCount = 0
        for index in note.features.indices {
            let delay = index == note.features.startIndex
                ? BatonReleaseNoteEntranceTiming.featureStartDelay
                : BatonReleaseNoteEntranceTiming.featureInterval
            guard await sleep(delay) else { return }
            withAnimation(.easeOut(duration: BatonReleaseNoteEntranceTiming.featureDuration)) {
                visibleFeatureCount = index + 1
            }
        }
    }

    private func startEntranceEffectsAfterSheetSettles() {
        guard entranceTask == nil else { return }
        isFeatureContainerVisible = false
        visibleFeatureCount = 0
        isConfirmEnabled = false
        entranceTask = Task { @MainActor in
            guard await sleep(BatonReleaseNoteEntranceTiming.sheetSettledDelay) else { return }
            logoGlintTrigger += 1
            guard await sleep(BatonReleaseNoteEntranceTiming.versionGlintDelayAfterLogoGlint) else { return }
            versionGlintTrigger += 1
            guard await sleep(BatonReleaseNoteEntranceTiming.featureContainerDelayAfterVersionGlint) else { return }
            withAnimation(.easeOut(duration: BatonReleaseNoteEntranceTiming.featureContainerDuration)) {
                isFeatureContainerVisible = true
            }
            guard await sleep(BatonReleaseNoteEntranceTiming.featureContainerDuration) else { return }
            await revealFeatures()
            guard await sleep(BatonReleaseNoteEntranceTiming.confirmEnableDelayAfterFeatures) else { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                isConfirmEnabled = true
            }
            entranceTask = nil
        }
    }

    private func sleep(_ duration: TimeInterval) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}

private enum BatonReleaseNoteColors {
    static let primary = Color.blue
    static let secondary = Color(red: 0.92, green: 0.34, blue: 0.29)
}

private enum BatonReleaseNoteEntranceTiming {
    static let sheetSettledDelay: TimeInterval = 0.15
    static let logoGlintDuration: TimeInterval = 0.75
    static let versionGlintDuration: TimeInterval = 0.75
    static let versionGlintDelay = sheetSettledDelay + 0.3
    static let versionGlintDelayAfterLogoGlint = versionGlintDelay - sheetSettledDelay
    static let featureContainerDelay = versionGlintDelay + 0.3
    static let featureContainerDelayAfterVersionGlint = featureContainerDelay - versionGlintDelay
    static let featureContainerDuration: TimeInterval = 0.22
    static let featureStartDelay: TimeInterval = 0
    static let featureDuration: TimeInterval = 0.28
    static let featureInterval: TimeInterval = 0.34
    static let confirmEnableDelayAfterFeatures = featureDuration + 0.08
}

private struct BatonReleaseNoteConfirmButtonAura: View {
    let phase: Angle
    let isActive: Bool

    var body: some View {
        ZStack {
            auraGlow(lineWidth: 10).blur(radius: 9).opacity(0.28)
            auraGlow(lineWidth: 5.6).blur(radius: 5).opacity(0.72)
            auraStroke(lineWidth: 1.2).blur(radius: 0.25)
        }
        .opacity(isActive ? 1 : 0)
        .allowsHitTesting(false)
    }

    private func auraGlow(lineWidth: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(auraGradient, lineWidth: lineWidth)
    }

    private func auraStroke(lineWidth: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(auraGradient, lineWidth: lineWidth)
    }

    private var auraGradient: AngularGradient {
        AngularGradient(
            colors: [
                BatonReleaseNoteColors.primary.opacity(0.32),
                Color.cyan.opacity(0.62),
                Color.white.opacity(0.34),
                BatonReleaseNoteColors.secondary.opacity(0.48),
                Color.mint.opacity(0.34),
                BatonReleaseNoteColors.primary.opacity(0.32)
            ],
            center: .center,
            startAngle: phase,
            endAngle: phase + .degrees(360)
        )
    }
}

private struct BatonReleaseNoteFeatureItemRow: View {
    let index: Int
    let feature: ReleaseNote.Feature

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().fill(BatonReleaseNoteColors.primary.opacity(0.12))
                Image(systemName: feature.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(BatonReleaseNoteColors.primary)
            }
            .frame(width: 34, height: 34)
            Text(feature.detail)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 15)
        .padding(.horizontal, 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String.localizedStringWithFormat(
                String(localized: "更新 %lld: %@"),
                Int64(index + 1),
                feature.detail
            )
        )
    }
}

private struct BatonReleaseNoteGlintEffectView: View {
    let trigger: Int
    var lastTrigger = -1
    var angle: Angle = .degrees(20)
    var duration: TimeInterval = 0.8
    var startDelay: TimeInterval = 0.05
    @State private var progress: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let diagonal = sqrt(width * width + height * height)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white.opacity(0.6), location: 0.5),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: diagonal * 0.8, height: diagonal * 1.8)
            .rotationEffect(angle)
            .position(x: width / 2 + progress * diagonal, y: height / 2)
            .opacity(trigger > lastTrigger ? 1 : 0)
            .onChange(of: trigger, initial: true) { oldValue, newValue in
                if newValue > lastTrigger || newValue > oldValue { executeAnimation() }
            }
        }
    }

    private func executeAnimation() {
        progress = -1
        DispatchQueue.main.asyncAfter(deadline: .now() + startDelay) {
            withAnimation(.easeInOut(duration: duration)) { progress = 1.5 }
        }
    }
}

private enum BatonReleaseNoteHaptics {
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
