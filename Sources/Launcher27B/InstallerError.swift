import Foundation

enum InstallerError: LocalizedError, AppLocalizableError, Equatable {
    case insufficientDiskSpace(required: Int64, available: Int64)
    case checksumMismatch(component: InstallationComponent)
    case runtimeArchiveInvalid
    case commandFailed(command: String, status: Int32)
    case diskFull
    case permissionDenied
    case sourceMissing(component: InstallationComponent)
    case fileOperationFailed(underlying: String)

    var errorDescription: String? {
        switch self {
        case let .insufficientDiskSpace(required, available):
            let requiredText = required.formatted(.byteCount(style: .file))
            let availableText = available.formatted(.byteCount(style: .file))
            return "磁盘空间不足：至少需要 \(requiredText)，当前可用 \(availableText)"
        case let .checksumMismatch(component):
            return "\(component.title) 校验失败，已保留已下载的文件；可重新校验或重试下载"
        case .runtimeArchiveInvalid:
            return "Prism 运行时压缩包缺少 llama-server 或必要动态库"
        case let .commandFailed(command, status):
            return "配置命令失败：\(command)（状态码 \(status)）"
        case .diskFull:
            return "磁盘空间不足，安装已停止；已保留已下载的文件，清理磁盘后可继续。"
        case .permissionDenied:
            return "无法写入目标文件夹；请检查文件夹权限后重试。"
        case let .sourceMissing(component):
            return "\(component.title) 的下载文件已丢失；请重新下载。"
        case let .fileOperationFailed(underlying):
            return "安装文件时发生错误：\(underlying)"
        }
    }

    @MainActor
    func localizedDescription(using preferences: AppPreferences) -> String {
        switch self {
        case let .insufficientDiskSpace(required, available):
            let requiredText = required.formatted(.byteCount(style: .file))
            let availableText = available.formatted(.byteCount(style: .file))
            return preferences.localizedFormat(
                "磁盘空间不足：至少需要 %@，当前可用 %@",
                requiredText,
                availableText
            )
        case let .checksumMismatch(component):
            return preferences.localizedFormat(
                "%@ 校验失败，已保留已下载的文件；可重新校验或重试下载",
                preferences.localized(component.title)
            )
        case .runtimeArchiveInvalid:
            return preferences.localized("Prism 运行时压缩包缺少 llama-server 或必要动态库")
        case let .commandFailed(command, status):
            return preferences.localizedFormat(
                "配置命令失败：%@（状态码 %lld）",
                command,
                Int64(status)
            )
        case .diskFull:
            return preferences.localized(
                "磁盘空间不足，安装已停止；已保留已下载的文件，清理磁盘后可继续。"
            )
        case .permissionDenied:
            return preferences.localized("无法写入目标文件夹；请检查文件夹权限后重试。")
        case let .sourceMissing(component):
            return preferences.localizedFormat(
                "%@ 的下载文件已丢失；请重新下载。",
                preferences.localized(component.title)
            )
        case .fileOperationFailed:
            return preferences.localized("安装文件时发生错误；请重试，已下载的文件会保留。")
        }
    }

    /// Rewrites raw Foundation file-system failures into localized installer errors.
    ///
    /// The developer-facing `errorDescription` of `fileOperationFailed` keeps the
    /// underlying text for logs; the user-facing localization stays actionable.
    static func wrapping(_ error: Error) -> Error {
        if error is CancellationError || error is InstallerError {
            return error
        }
        if let downloadError = error as? ArtifactDownloadError {
            return downloadError
        }
        if FileSystemFailure.isOutOfSpace(error) {
            return InstallerError.diskFull
        }
        if FileSystemFailure.isPermissionDenied(error) {
            return InstallerError.permissionDenied
        }
        return InstallerError.fileOperationFailed(
            underlying: (error as NSError).localizedDescription
        )
    }
}
