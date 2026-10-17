import SwiftUI
import AppKit
import AskIslandCore

@MainActor
final class QuestionCardState: ObservableObject {
    @Published var selectedOptions: [Int: Set<String>] = [:]
    @Published var textAnswers: [Int: String] = [:]
    private var currentRequestId: String = ""

    func sync(with request: AskRequest) {
        if currentRequestId != request.id {
            currentRequestId = request.id
            selectedOptions = [:]
            textAnswers = [:]
        }
    }

    func isSubmitEnabled(for request: AskRequest) -> Bool {
        guard !request.questions.isEmpty else { return false }
        for (i, _) in request.questions.enumerated() {
            let hasSelection = !(selectedOptions[i]?.isEmpty ?? true)
            let text = textAnswers[i]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hasText = !text.isEmpty
            if !hasSelection && !hasText {
                return false
            }
        }
        return true
    }

    func firstUnansweredQuestionIndex(for request: AskRequest) -> Int? {
        for (i, _) in request.questions.enumerated() {
            let hasSelection = !(selectedOptions[i]?.isEmpty ?? true)
            let text = textAnswers[i]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hasText = !text.isEmpty
            if !hasSelection && !hasText {
                return i
            }
        }
        return nil
    }

    func toggleOption(for request: AskRequest, optionIndex: Int) -> Bool {
        let targetIndex = firstUnansweredQuestionIndex(for: request) ?? 0
        guard targetIndex < request.questions.count else { return false }
        let question = request.questions[targetIndex]
        guard optionIndex >= 0 && optionIndex < question.options.count else { return false }
        let label = question.options[optionIndex].label

        if question.multiSelect {
            var current = selectedOptions[targetIndex] ?? []
            if current.contains(label) {
                current.remove(label)
            } else {
                current.insert(label)
            }
            selectedOptions[targetIndex] = current
        } else {
            selectedOptions[targetIndex] = [label]
        }
        return true
    }

    func submit(for request: AskRequest, store: AskStore) {
        var answers: [AskAnswer] = []
        for (i, question) in request.questions.enumerated() {
            let selectedSet = selectedOptions[i] ?? []
            let inOrder = question.options.map(\.label).filter { selectedSet.contains($0) }
            let text = textAnswers[i]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let textAnswer = text.isEmpty ? nil : text
            answers.append(AskAnswer(selected: inOrder, text: textAnswer))
        }
        store.resolve(request.id, AskResponse(id: request.id, status: .answered, answers: answers))
    }
}

struct OptionRowView: View {
    let questionIndex: Int
    let question: AskQuestion
    let option: AskOption
    let isSelected: Bool
    let onToggle: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                    if let desc = option.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.55))
                    }
                }
                .textHalo()

                Spacer()

                if question.multiSelect {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 16))
                        .foregroundColor(isSelected ? Color(nsColor: .systemBlue) : .white.opacity(0.35))
                } else {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundColor(isSelected ? Color(nsColor: .systemBlue) : .white.opacity(0.35))
                }
            }
            .padding(.horizontal, CardMetrics.rowInset)
            .padding(.vertical, 8)
            .frame(minHeight: 40)
            .contentShape(RoundedRectangle(cornerRadius: CardMetrics.rowRadius, style: .continuous))
            .background(
                // Hover: a soft frosted tile behind the whole row, bleeding slightly past the text column.
                RoundedRectangle(cornerRadius: CardMetrics.rowRadius, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.12 : 0))
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -CardMetrics.rowInset)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
    }
}

struct QuestionCardView: View {
    let request: AskRequest
    @ObservedObject var store: AskStore
    @ObservedObject var cardState: QuestionCardState
    var onFocusTextField: () -> Void

    @FocusState private var focusedQuestionIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Title & Detail
            VStack(alignment: .leading, spacing: 6) {
                Text(request.title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = request.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.7))
                        .textSelection(.enabled)
                }
            }
            .textHalo()

            // Questions
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(request.questions.enumerated()), id: \.offset) { index, question in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.white.opacity(0.14))
                            .frame(height: 1)
                    }
                    questionSection(index: index, question: question)
                }
            }

            CardToolbar {
                Button("Decline") {
                    store.resolve(request.id, AskResponse(id: request.id, status: .declined, answers: []))
                }
                .capsuleButton(prominent: false)

                Button("Submit") {
                    cardState.submit(for: request, store: store)
                }
                .capsuleButton(prominent: true)
                .disabled(!cardState.isSubmitEnabled(for: request))
            }
        }
        .onAppear {
            cardState.sync(with: request)
        }
        .onChange(of: request.id) { _, _ in
            cardState.sync(with: request)
        }
        .onChange(of: focusedQuestionIndex) { _, newValue in
            if newValue != nil {
                onFocusTextField()
            }
        }
    }

    @ViewBuilder
    private func questionSection(index: Int, question: AskQuestion) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            let hasHeader = question.header != nil && !question.header!.isEmpty
            let showQuestionText = !(request.questions.count == 1 && question.question == request.title)

            if hasHeader || showQuestionText {
                HStack(spacing: 6) {
                    if let header = question.header, !header.isEmpty {
                        Text(header)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.55))
                    }
                    if showQuestionText {
                        if hasHeader {
                            Text("·")
                                .foregroundColor(.white.opacity(0.35))
                        }
                        Text(question.question)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.55))
                    }
                }
                .padding(.vertical, 6)
                .textHalo()
            }

            // Options separated by 1 px hairlines of white 0.14
            if !question.options.isEmpty {
                VStack(spacing: 2) {
                    ForEach(Array(question.options.enumerated()), id: \.element.label) { optIndex, option in
                        OptionRowView(
                            questionIndex: index,
                            question: question,
                            option: option,
                            isSelected: cardState.selectedOptions[index]?.contains(option.label) ?? false,
                            onToggle: {
                                if question.multiSelect {
                                    var current = cardState.selectedOptions[index] ?? []
                                    if current.contains(option.label) {
                                        current.remove(option.label)
                                    } else {
                                        current.insert(option.label)
                                    }
                                    cardState.selectedOptions[index] = current
                                } else {
                                    cardState.selectedOptions[index] = [option.label]
                                }
                            }
                        )
                    }
                }
            }

            // Text Field as a borderless row with placeholder in white 0.4 and a hairline, no box
            if question.allowText {
                let placeholder = question.options.isEmpty ? "Type your answer" : "Other (optional)"
                let textBinding = Binding<String>(
                    get: { cardState.textAnswers[index] ?? "" },
                    set: { cardState.textAnswers[index] = $0 }
                )

                CardTextField(placeholder: placeholder, text: textBinding)
                    .focused($focusedQuestionIndex, equals: index)
                    .padding(.top, 6)
            }
        }
    }
}

struct ActionCardView: View {
    let request: AskRequest
    @ObservedObject var store: AskStore
    var onFocusTextField: () -> Void

    @State private var note: String = ""
    @FocusState private var isNoteFocused: Bool

    private var symbolForKind: String {
        switch request.actionKind {
        case .computer: return "desktopcomputer"
        case .phone: return "iphone"
        case .password: return "key.fill"
        case .login: return "person.badge.key"
        case .other, .none: return "hand.raised"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Icon & Title
            HStack(spacing: 10) {
                Image(systemName: symbolForKind)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)

                Text(request.title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .textHalo()

            // Detail
            if let detail = request.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.7))
                    .textSelection(.enabled)
                    .textHalo()
            }

            // Password warning as a row with lock.fill in systemOrange
            if request.actionKind == .password {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Type the password where it asks for it. Never send it to the agent.")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(Color(nsColor: .systemOrange))
                .padding(.horizontal, 4)
                .frame(minHeight: 36, alignment: .leading)
            }

            // Note field as a borderless row with placeholder in white 0.4 and a hairline, no box
            CardTextField(placeholder: "Note (optional)", text: $note)
                .focused($isNoteFocused)

            CardToolbar {
                Button("Can't do it") {
                    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.resolve(request.id, AskResponse(id: request.id, status: .declined, answers: [], note: trimmed.isEmpty ? nil : trimmed))
                }
                .capsuleButton(prominent: false)

                Button("Done") {
                    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.resolve(request.id, AskResponse(id: request.id, status: .done, answers: [], note: trimmed.isEmpty ? nil : trimmed))
                }
                .capsuleButton(prominent: true)
            }
        }
        .onChange(of: isNoteFocused) { _, newValue in
            if newValue {
                onFocusTextField()
            }
        }
    }
}

struct NotifyCardView: View {
    let request: AskRequest
    @ObservedObject var store: AskStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Title
            Text(request.title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
                .textHalo()

            // Detail
            if let detail = request.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.7))
                    .textSelection(.enabled)
                    .textHalo()
            }

            CardToolbar {
                Button("Got it") {
                    store.resolve(request.id, AskResponse(id: request.id, status: .dismissed, answers: [], note: nil))
                }
                .capsuleButton(prominent: true)
            }
        }
    }
}


// MARK: - Shared card pieces

enum CardMetrics {
    /// Rows and fields sit `rowInset` past the text column on each side, so their hover tile / field box
    /// bleeds a little while the text stays aligned with the title.
    static let rowInset: CGFloat = 10
    static let rowRadius: CGFloat = 12
}

/// Bottom bar of every card, as in a macOS 26 compose sheet: the secondary (frosted) and primary (blue)
/// capsules, right-aligned.
struct CardToolbar<Buttons: View>: View {
    @ViewBuilder var buttons: Buttons

    var body: some View {
        HStack(spacing: 10) {
            Spacer()
            buttons
        }
        .padding(.top, 6)
    }
}

extension View {
    func capsuleButton(prominent: Bool) -> some View {
        buttonStyle(GlassCapsuleButtonStyle(prominent: prominent))
    }
}

/// Liquid Glass capsules: clear glass for the secondary action, blue-tinted glass for the primary one. Drawn
/// with `glassEffect` instead of the system `.glass` button styles, which render as greyed-out inactive
/// controls whenever the (non-activating) panel is not the key window.
struct GlassCapsuleButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        // The blue is a plain fill on top of the glass: a glass tint fades to grey whenever the panel is not
        // the key window, and the buttons must look the same with or without focus.
        let fill = prominent ? Color(nsColor: .systemBlue).opacity(isEnabled ? 0.9 : 0.35) : Color.clear
        return configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white.opacity(isEnabled ? 1 : 0.6))
            .padding(.horizontal, 20)
            .frame(height: 36)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
            .glassEffect(.regular.interactive(), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A soft frosted field instead of a hairline row.
struct CardTextField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        // Wraps instead of scrolling sideways: a single-line field scrolls its text under the right edge,
        // and IME marked text (pinyin) past the edge is not scrolled into view at all. Grows up to 4 lines.
        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(.white.opacity(0.4)), axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...4)
            .font(.system(size: 14))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, CardMetrics.rowInset)
            .padding(.vertical, 10)
            .frame(minHeight: 38)
            .background(
                RoundedRectangle(cornerRadius: CardMetrics.rowRadius, style: .continuous)
                    .fill(Color.white.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: CardMetrics.rowRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75)
            )
            .padding(.horizontal, -CardMetrics.rowInset)
    }
}

extension View {
    /// Text sits on clear glass over any wallpaper: a soft dark halo keeps it legible. Text only, so buttons
    /// and fields stay clean.
    func textHalo() -> some View {
        shadow(color: .black.opacity(0.45), radius: 2.5)
    }
}
