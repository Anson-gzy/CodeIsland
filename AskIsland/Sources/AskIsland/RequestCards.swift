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
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
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
                    .lineLimit(2)

                if let detail = request.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.7))
                        .textSelection(.enabled)
                }
            }

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

            // Bottom toolbar after a hairline
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.white.opacity(0.14))
                    .frame(height: 1)

                HStack {
                    // Primary action on the left: Submit
                    Button(action: {
                        cardState.submit(for: request, store: store)
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Submit")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 32)
                        .background(
                            Capsule()
                                .fill(Color(nsColor: .systemBlue).opacity(cardState.isSubmitEnabled(for: request) ? 1.0 : 0.35))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!cardState.isSubmitEnabled(for: request))

                    Spacer()

                    // Secondary action on the right: Decline
                    Button(action: {
                        store.resolve(request.id, AskResponse(id: request.id, status: .declined, answers: []))
                    }) {
                        Text("Decline")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 14)
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
            }

            // Options separated by 1 px hairlines of white 0.14
            if !question.options.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(question.options.enumerated()), id: \.element.label) { optIndex, option in
                        Rectangle()
                            .fill(Color.white.opacity(0.14))
                            .frame(height: 1)

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

                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.white.opacity(0.14))
                        .frame(height: 1)

                    TextField("", text: textBinding, prompt: Text(placeholder).foregroundColor(.white.opacity(0.4)))
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .frame(height: 42)
                        .focused($focusedQuestionIndex, equals: index)
                }
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
                    .lineLimit(2)
            }

            // Detail
            if let detail = request.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.7))
                    .textSelection(.enabled)
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
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.white.opacity(0.14))
                    .frame(height: 1)

                TextField("", text: $note, prompt: Text("Note (optional)").foregroundColor(.white.opacity(0.4)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .frame(height: 42)
                    .focused($isNoteFocused)
            }

            // Bottom toolbar after a hairline
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.white.opacity(0.14))
                    .frame(height: 1)

                HStack {
                    // Primary action on the left: Done
                    Button(action: {
                        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.resolve(request.id, AskResponse(id: request.id, status: .done, answers: [], note: trimmed.isEmpty ? nil : trimmed))
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Done")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 32)
                        .background(
                            Capsule()
                                .fill(Color(nsColor: .systemBlue))
                        )
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    // Secondary action on the right: Can't do it
                    Button(action: {
                        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.resolve(request.id, AskResponse(id: request.id, status: .declined, answers: [], note: trimmed.isEmpty ? nil : trimmed))
                    }) {
                        Text("Can't do it")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 14)
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
                .lineLimit(2)

            // Detail
            if let detail = request.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.7))
                    .textSelection(.enabled)
            }

            // Bottom toolbar after a hairline
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.white.opacity(0.14))
                    .frame(height: 1)

                HStack {
                    // Primary action on the left: Got it (no icon)
                    Button(action: {
                        store.resolve(request.id, AskResponse(id: request.id, status: .dismissed, answers: [], note: nil))
                    }) {
                        Text("Got it")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 18)
                            .frame(height: 32)
                            .background(
                                Capsule()
                                    .fill(Color(nsColor: .systemBlue))
                            )
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
                .padding(.top, 14)
            }
        }
    }
}
