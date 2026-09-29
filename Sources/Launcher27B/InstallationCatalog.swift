import Foundation

struct InstallationCatalog: Sendable {
    static let runtimeRelease = "prism-b10683-d8f26ee"
    static let modelRevision = "6ed5e12bf84b7a63069882c91dd9e9218647d17b"
    static let adapterRevision = "947a80cd1d3b4f9a97417025e6c2c62223571287"

    func artifacts(for config: LauncherConfig) -> [InstallationArtifact] {
        let runtimeDirectory = config.serverBinary.deletingLastPathComponent()

        return [
            InstallationArtifact(
                component: .runtime,
                downloadURL: Self.url(
                    "https://github.com/PrismML-Eng/llama.cpp/releases/download/\(Self.runtimeRelease)/llama-\(Self.runtimeRelease)-bin-macos-arm64.tar.gz"
                ),
                destinationURL: runtimeDirectory,
                expectedByteCount: 11_663_242,
                expectedSHA256: "0ae163ca2c9cce92470316ed743f76985beea4d5cf31b8dc546711cf6fc8dd35",
                kind: .runtimeArchive(releaseMarker: Self.runtimeRelease)
            ),
            InstallationArtifact(
                component: .model,
                downloadURL: Self.huggingFaceURL(
                    fileName: "Ternary-Bonsai-2-27B-PQ2_0.gguf"
                ),
                destinationURL: config.modelFile,
                expectedByteCount: 7_206_168_928,
                expectedSHA256: "3907dc1658db1f78a9826bf8d5bcb8dc65db0d466388937af57f2294fae62ec1",
                kind: .file
            ),
            InstallationArtifact(
                component: .projector,
                downloadURL: Self.huggingFaceURL(
                    fileName: "Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf"
                ),
                destinationURL: config.projectorFile,
                expectedByteCount: 629_246_976,
                expectedSHA256: "6807ede61d570bb86ba34b756a0fa109edc33668604de867c6ea6d8f1d631903",
                kind: .file
            ),
            InstallationArtifact(
                component: .adapter,
                downloadURL: Self.url(
                    "https://raw.githubusercontent.com/Continuum-AI-Corp/OrcaBonsai-27B-Uncensored/\(Self.adapterRevision)/gguf/bonsai-abliterate-lora.gguf"
                ),
                destinationURL: config.ablationAdapterFile,
                expectedByteCount: 9_682_464,
                expectedSHA256: "f1669534803d340a496015f5c45125f3437b4d13ec764f40e34488ce83967f42",
                kind: .file
            )
        ]
    }

    private static func huggingFaceURL(fileName: String) -> URL {
        url(
            "https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf/resolve/\(modelRevision)/\(fileName)?download=true"
        )
    }

    private static func url(_ value: String) -> URL {
        guard let url = URL(string: value) else {
            fatalError("Invalid bundled installation URL: \(value)")
        }
        return url
    }
}
