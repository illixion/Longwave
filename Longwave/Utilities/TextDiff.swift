import Foundation

/// Computes the edit between two text-field snapshots as a **common-prefix
/// delta**: how many trailing characters were removed, and what new trailing
/// text to type. Always yields the correct final string by deleting the
/// changed tail and retyping it.
///
/// This replaces the old append-only diff (`new.suffix(new.count - old.count)`
/// guarded by `new.count > old.count`), which silently dropped deletions — so
/// backspace was never sent — and corrupted dictation's mid-string rewrites.
/// It assumes edits are anchored at the end of the field (typing, dictation
/// appending/rewriting the tail); a mid-string local edit would over-delete,
/// which the old approach handled no better.
nonisolated enum TextDiff {
    struct Delta: Equatable {
        /// Backspaces to emit for the removed tail.
        var deleteCount: Int
        /// New tail to type after the common prefix.
        var insert: String
    }

    static func delta(old: String, new: String) -> Delta {
        let o = Array(old)
        let n = Array(new)
        let shared = min(o.count, n.count)
        var prefix = 0
        while prefix < shared && o[prefix] == n[prefix] { prefix += 1 }
        return Delta(deleteCount: o.count - prefix, insert: String(n[prefix...]))
    }
}
