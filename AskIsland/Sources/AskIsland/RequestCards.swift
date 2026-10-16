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

struct QuestionCardView: View {
    let request: AskRequest
    @ObservedObject var store: AskStore
    @ObservedObject var cardState: QuestionCardState
    var onFocusTextField: () -> Void

    @FocusState private var focusedQuestionIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Title
            Text(request.title)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(2)

            // Detail
            if let detail = request.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }

            // Questions
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(request.questions.enumerated()), id: \.offset) { index, question in
                    questionSection(index: index, question: question)
                }
            }

            // Buttons
            HStack(spacing: 12) {
                Button(action: {
                    store.resolve(request.id, AskResponse(id: request.id, status: .declined, answers: []))
                }) {
                    Text("拒绝回答")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.75))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: {
                    cardState.submit(for: request, store: store)
                }) {
                    Text("提交")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(cardState.isSubmitEnabled(for: request) ? Color.accentColor : Color.white.opacity(0.15))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!cardState.isSubmitEnabled(for: request))
            }
            .padding(.top, 4)
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
        VStack(alignment: .leading, spacing: 8) {
            // Header chip & Question text
            HStack(spacing: 6) {
                if let header = question.header, !header.isEmpty {
                    Text(header)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.accentColor.opacity(0.15))
                        )
                }
                // A single question whose text is already the card title would read twice.
                if !(request.questions.count == 1 && question.question == request.title) {
                    Text(question.question)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                }
            }

            // Options
            if !question.options.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(question.options, id: \.label) { option in
                        optionRow(questionIndex: index, question: question, option: option)
                    }
                }
            }

            // Text Field
            if question.allowText {
                let placeholder = question.options.isEmpty ? "输入回答" : "其他（可选）"
                let textBinding = Binding<String>(
                    get: { cardState.textAnswers[index] ?? "" },
                    set: { cardState.textAnswers[index] = $0 }
                )

                TextField("", text: textBinding, prompt: Text(placeholder).foregroundColor(.white.opacity(0.4)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.white.opacity(0.08))
                    )
                    .focused($focusedQuestionIndex, equals: index)
            }
        }
    }

    @ViewBuilder
    private func optionRow(questionIndex: Int, question: AskQuestion, option: AskOption) -> some View {
        let isSelected = cardState.selectedOptions[questionIndex]?.contains(option.label) ?? false

        Button(action: {
            if question.multiSelect {
                var current = cardState.selectedOptions[questionIndex] ?? []
                if isSelected {
                    current.remove(option.label)
                } else {
                    current.insert(option.label)
                }
                cardState.selectedOptions[questionIndex] = current
            } else {
                cardState.selectedOptions[questionIndex] = [option.label]
            }
        }) {
            HStack(alignment: .top, spacing: 8) {
                if question.multiSelect {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 13))
                        .foregroundColor(isSelected ? .accentColor : .white.opacity(0.5))
                        .padding(.top, 2)
                } else {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 13))
                        .foregroundColor(isSelected ? .accentColor : .white.opacity(0.5))
                        .padding(.top, 2)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                    if let desc = option.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.white.opacity(0.06) : Color.clear)
            )
        }
        .buttonStyle(.plain)
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
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 24, height: 24)

                Text(request.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
            }

            // Detail
            if let detail = request.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }

            // Password hint if password kind
            if request.actionKind == .password {
                Text("密码请在它提示的地方输入，不要发给 agent")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.orange)
            }

            // Note field
            TextField("", text: $note, prompt: Text("备注（可选）").foregroundColor(.white.opacity(0.4)))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.white.opacity(0.08))
                )
                .focused($isNoteFocused)

            // Buttons
            HStack(spacing: 12) {
                Button(action: {
                    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.resolve(request.id, AskResponse(id: request.id, status: .declined, answers: [], note: trimmed.isEmpty ? nil : trimmed))
                }) {
                    Text("做不了")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.75))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: {
                    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.resolve(request.id, AskResponse(id: request.id, status: .done, answers: [], note: trimmed.isEmpty ? nil : trimmed))
                }) {
                    Text("我已完成")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.accentColor)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
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
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(2)

            // Detail
            if let detail = request.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }

            // Button
            HStack {
                Spacer()
                Button(action: {
                    store.resolve(request.id, AskResponse(id: request.id, status: .dismissed, answers: [], note: nil))
                }) {
                    Text("知道了")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.accentColor)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
    }
}
