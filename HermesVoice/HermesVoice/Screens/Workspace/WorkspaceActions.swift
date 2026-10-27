import Foundation
import SwiftUI

/// What the panel can change on the host. The destructive and outward-facing ones ask first: revert, push (also
/// Commit & Push), create PR, branch switch, worktree removal.
enum WorkspaceAction: Hashable {
    case stage(file: String?)
    case unstage(file: String?)
    /// nil reverts every change.
    case revert(file: String?)
    case commit(message: String, push: Bool, branch: String?)
    case push(branch: String?)
    case createPR(branch: String?)
    case switchBranch(String)
    case removeWorktree(path: String, force: Bool)

    /// The question asked before it runs; nil runs at once.
    var confirmation: WorkspaceConfirmation? {
        switch self {
        case .stage, .unstage, .commit(_, false, _):
            return nil
        case let .revert(file?):
            return WorkspaceConfirmation(
                title: "Revert",
                message: "Discard changes to this file and restore it to the committed state? This cannot be undone.\n\n\(file)",
                confirmLabel: "Revert")
        case .revert(nil):
            return WorkspaceConfirmation(
                title: "Revert all",
                message: "Discard every change and restore files to the committed state? This cannot be undone.",
                confirmLabel: "Revert all")
        case let .commit(_, true, branch):
            return WorkspaceConfirmation(
                title: "Commit & Push",
                message: "Commit the changes, then push \(Self.branchName(branch)) to its remote.",
                confirmLabel: "Commit & Push", destructive: false)
        case let .push(branch):
            return WorkspaceConfirmation(
                title: "Push",
                message: "Push \(Self.branchName(branch))'s commits to its remote? Hermes sets the upstream when there is none.",
                confirmLabel: "Push", destructive: false)
        case let .createPR(branch):
            return WorkspaceConfirmation(
                title: "Create PR",
                message: "Push \(Self.branchName(branch)) and open a pull request on GitHub with gh, titled and described from "
                    + "its commits?",
                confirmLabel: "Create PR", destructive: false)
        case let .switchBranch(branch):
            return WorkspaceConfirmation(
                title: "Switch to \(branch)?",
                message: "The repository's checkout moves to \(branch). Uncommitted changes come along, or stop the switch "
                    + "when they conflict.",
                confirmLabel: "Switch", destructive: false)
        case let .removeWorktree(path, false):
            return WorkspaceConfirmation(
                title: "Remove worktree",
                message: "Remove it from git? This deletes the worktree folder; the branch stays.\n\n\(path)",
                confirmLabel: "Remove")
        case let .removeWorktree(path, true):
            return WorkspaceConfirmation(
                title: "Force-remove worktree",
                message: "This worktree has uncommitted changes. Force-removing it discards those changes.\n\n\(path)",
                confirmLabel: "Force remove")
        }
    }

    private static func branchName(_ branch: String?) -> String {
        branch.map { "“\($0)”" } ?? "this branch"
    }
}

struct WorkspaceConfirmation: Hashable {
    var title: String
    var message: String
    var confirmLabel: String
    var destructive = true
}

/// Runs workspace actions, holding the ones that ask first until the user says yes.
@MainActor
final class WorkspaceActionGate: ObservableObject {
    @Published private(set) var pending: WorkspaceAction?
    private let perform: (WorkspaceAction) async -> Void

    init(perform: @escaping (WorkspaceAction) async -> Void) {
        self.perform = perform
    }

    /// Runs `action`, or holds it for `confirm()` when it asks first.
    func request(_ action: WorkspaceAction) async {
        if action.confirmation != nil {
            pending = action
        } else {
            await perform(action)
        }
    }

    /// Runs the held action. Synchronous up to the hand-off, so an alert closing right after can't drop it.
    @discardableResult
    func confirm() -> Task<Void, Never>? {
        guard let action = pending else { return nil }
        pending = nil
        let perform = perform
        return Task { await perform(action) }
    }

    func cancel() {
        pending = nil
    }
}

extension View {
    /// The gate's pending question as an alert.
    func workspaceConfirm(_ gate: WorkspaceActionGate) -> some View {
        modifier(WorkspaceConfirmModifier(gate: gate))
    }
}

private struct WorkspaceConfirmModifier: ViewModifier {
    @ObservedObject var gate: WorkspaceActionGate

    func body(content: Content) -> some View {
        let confirmation = gate.pending?.confirmation
        content.alert(confirmation?.title ?? "",
                      isPresented: Binding(get: { gate.pending != nil }, set: { if !$0 { gate.cancel() } }),
                      presenting: confirmation) { pending in
            Button(pending.confirmLabel, role: pending.destructive ? .destructive : nil) {
                gate.confirm()
            }
            Button("Cancel", role: .cancel) { gate.cancel() }
        } message: { pending in
            Text(pending.message)
        }
    }
}
