import SwiftUI

/// A labeled dropdown for choosing an alert sound, with a play button next to each
/// option so it can be previewed without selecting it. A native SwiftUI `Picker`
/// can't do this — choosing an item *is* the only interaction it exposes — so this
/// is a custom popover with its own tap targets: the name selects, a separate ▶
/// icon previews.
struct SoundPickerRow: View {
    let title: String
    @Binding var selection: String
    let volume: Float
    let onSelect: () -> Void

    @State private var expanded = false

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button {
                expanded = true
            } label: {
                HStack(spacing: 4) {
                    Text(selection)
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $expanded) {
                SoundPickerMenu(selection: $selection, volume: volume) {
                    onSelect()
                    expanded = false
                }
            }
        }
    }
}

private struct SoundPickerMenu: View {
    @Binding var selection: String
    let volume: Float
    let onCommit: () -> Void

    /// Which row the pointer is currently over, so hovering gives a clear visual
    /// cue about which sound a click would land on — separate from `selection`,
    /// which marks what's actually chosen.
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(SoundLibrary.groups.enumerated()), id: \.element.name) { i, group in
                Text(group.name)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, i == 0 ? 6 : 10)
                    .padding(.horizontal, 12)

                ForEach(group.sounds, id: \.self) { sound in
                    row(sound)
                }
            }
        }
        .padding(.vertical, 6)
        // Sized to content (longest name is "Submarine") rather than a wide fixed
        // frame — a flexible Spacer inside a too-wide frame was pushing the ▶
        // button far from short names like "Pop" or "Tink".
        .frame(width: 132)
    }

    private func row(_ sound: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.tint)
                .opacity(selection == sound ? 1 : 0)
                .frame(width: 11)

            Text(sound)
                .font(.system(size: 12))
                .lineLimit(1)

            Spacer(minLength: 6)

            // Separate tap target from the row itself — clicking this previews the
            // sound without changing the selection or closing the popover.
            Button {
                SoundLibrary.play(sound, volume: volume)
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor.opacity(hovered == sound ? 0.16 : 0))
        )
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? sound : (hovered == sound ? nil : hovered) }
        .onTapGesture {
            // Play even when re-selecting the sound that's already chosen — clicking
            // a name is as much "hear it" as it is "pick it".
            selection = sound
            SoundLibrary.play(sound, volume: volume)
            onCommit()
        }
    }
}
