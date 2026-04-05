//
//  SoundPickerRow.swift
//  ClaudeIsland
//
//  Notification sound selection picker for settings menu
//

import AppKit
import Combine
import SwiftUI

// MARK: - Root View (two rows)

struct SoundPickerRows: View {
    @StateObject private var completionSelector = PickerState()
    @StateObject private var attentionSelector = PickerState()

    var body: some View {
        VStack(spacing: 0) {
            SoundPickerSection(
                title: "Task Complete Sound",
                icon: "checkmark.circle",
                state: completionSelector,
                soundKey: .completion
            )

            // Separator
            Rectangle()
                .fill(Color.white.opacity(0.05))
                .frame(height: 1)
                .padding(.vertical, 4)

            SoundPickerSection(
                title: "Needs Attention Sound",
                icon: "exclamationmark.circle",
                state: attentionSelector,
                soundKey: .attention
            )
        }
    }
}

// MARK: - Sound Key

enum SoundKey {
    case completion
    case attention
}

// MARK: - Picker State (per-section)

private final class PickerState: ObservableObject {
    @Published var isExpanded: Bool = false
}

// MARK: - Sound Picker Section

private struct SoundPickerSection: View {
    let title: String
    let icon: String
    @StateObject var state: PickerState
    let soundKey: SoundKey

    @State private var currentSound: NotificationSound = .none
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    state.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundColor(textColor)
                        .frame(width: 16)

                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(textColor)

                    Spacer()

                    Text(currentSound.rawValue)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)

                    Image(systemName: state.isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            if state.isExpanded {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(NotificationSound.allCases, id: \.self) { option in
                            SoundOptionRowInline(
                                sound: option,
                                isSelected: currentSound == option
                            ) {
                                if let bitSound = option.bitSound {
                                    SoundGenerator.shared.play(bitSound)
                                }
                                currentSound = option
                                save(option)
                            }
                        }
                    }
                }
                .frame(maxHeight: CGFloat(min(NotificationSound.allCases.count, 6)) * 32)
                .padding(.leading, 28)
                .padding(.top, 4)
            }
        }
        .onAppear {
            currentSound = load()
        }
    }

    private func load() -> NotificationSound {
        switch soundKey {
        case .completion: return AppSettings.notificationSound
        case .attention: return AppSettings.attentionSound
        }
    }

    private func save(_ sound: NotificationSound) {
        switch soundKey {
        case .completion: AppSettings.notificationSound = sound
        case .attention: AppSettings.attentionSound = sound
        }
    }

    private var textColor: Color {
        .white.opacity(isHovered ? 1.0 : 0.7)
    }
}

// MARK: - Sound Option Row (Inline version)

private struct SoundOptionRowInline: View {
    let sound: NotificationSound
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isSelected ? TerminalColors.green : Color.white.opacity(0.2))
                    .frame(width: 6, height: 6)

                Text(sound.rawValue)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.7))

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(TerminalColors.green)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
