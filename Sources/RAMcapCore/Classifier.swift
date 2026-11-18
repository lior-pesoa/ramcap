public enum Classifier {
    /// Maps a process's launch arguments to its kind and display type name.
    /// No `--type=` means the browser process itself.
    public static func classify(_ arguments: [String]) -> (kind: ProcessKind, typeName: String) {
        let type = arguments.lazy
            .first { $0.hasPrefix("--type=") }
            .map { String($0.dropFirst("--type=".count)) }

        switch type {
        case nil:
            return (.browser, "browser")
        case "renderer":
            return arguments.contains("--extension-process") ? (.extension_, "extension") : (.tab, "tab")
        case "gpu-process":
            return (.gpu, "gpu-process")
        case "utility":
            return (.utility, "utility")
        case let other?:
            return (.other, other)
        }
    }
}
