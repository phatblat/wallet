import ArgumentParser
import Crypto
import Foundation

extension Pass {
    struct Verify: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Unzip and verify a signed pass's signature and manifest.",
            discussion: "This DOES NOT validate pass content."
        )

        @Option(name: NameSpecification([
            NameSpecification.Element.short,
            NameSpecification.Element.customLong("path")]),
                help: "Path to signed .pkpass file to verify.")
        var packagePath: String?

        var packageUrl: URL?

        mutating func validate() throws {
            guard let path = packagePath else {
                throw ValidationError("Please provide path to the pass package.")
            }
            debugPrint("path: \(path)")
        }

        func run() throws {
            let currentDir = URL(fileURLWithPath: ".", isDirectory: true)
            debugPrint("currentDir: \(currentDir)")

            guard let path = packagePath else {
                throw ValidationError("Please provide path to the pass package.")
            }

            let passUrl = URL(fileURLWithPath: path, isDirectory: false, relativeTo: currentDir)
            debugPrint("passUrl: \(passUrl)")

            // get a temporary place to unpack the pass
            let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(passUrl.lastPathComponent, isDirectory: true)

            // unzip the pass there
            let process = Process()
            process.launchPath = "/usr/bin/unzip"
            process.arguments = ["-q", "-o", passUrl.path, "-d", tempDir.path]
            process.launch()
            process.waitUntilExit()

            guard !process.isRunning else { fatalError("unzip command is still running") }

            guard process.terminationStatus == 0 else {
                fatalError("Error unzipping pass: \(process.terminationStatus) \(process.terminationReason)")
            }

            debugPrint("unzip completed in \(tempDir.path)")
            debugPrint("extracted pass contents:")
            let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
            contents.forEach { file in
                debugPrint(" - \(file)")
            }

            let manifestUrl = tempDir.appendingPathComponent("manifest.json", isDirectory: false)

            _ = try validate(manifest: manifestUrl)
        }

        /// Validates a pass manifest.
        /// - Parameter manifest: File URL to the extracted pass manifest.
        func validate(manifest manifestUrl: URL) throws -> Bool {
            let data = try Data(contentsOf: manifestUrl)
            debugPrint("manifest.json: \(String(data: data, encoding: .utf8)!)")

            let manifest = try JSONSerialization.jsonObject(with: data, options: .init(rawValue: 0)) as! [String: String]
            var manifestCount = manifest.count

            guard let enumerator = FileManager.default.enumerator(at: manifestUrl.deletingLastPathComponent(),
                                                                  includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey])
                else { fatalError("Can't create directory enumerator") }

            for case let url as URL in enumerator {
                // Skip directories
                let resourceValues = try url.resourceValues(forKeys: Set<URLResourceKey>(arrayLiteral: .isDirectoryKey))
                if let isDir = resourceValues.isDirectory, isDir {
                    continue
                }

                let fileName = url.lastPathComponent
                debugPrint("fileName: \(fileName)")

                // No symlinks
                if let isLink = resourceValues.isSymbolicLink, isLink {
                    print("Pass contains a symlink, \(fileName), which is illegal")
                    return false
                }

                // Ignore manifest and signature
                if ["manifest.json", "signature"].contains(fileName) {
                    continue
                }

                guard let manifestHash = manifest[fileName] else {
                    print("No entry in manifest for file")
                    return false
                }
                debugPrint("manifestHash: \(manifestHash)")
                debugPrint("file SHA1: \(url.sha1)")

                // Compare SHA1 hash in manifest to that of file
                guard manifestHash == url.sha1 else {
                    print("For file \(fileName), manifest's listed SHA1 hash \(manifestHash) doesn't match computed hash, \(url.sha1)")
                    return false
                }

                // File hash is valid
                // Decrement count of files
                manifestCount -= 1
            }

            // Check for extra manifest entries not found in bundle
            if manifestCount != 0 {
                print("Pass is missing files listed in the manifest: \(manifest)")
                return false
            }

            return true
        }
    }
}

extension URL {
    var sha1: String {
        let data = try! Data(contentsOf: self)
        return Insecure.SHA1.hash(data: data)
            .map { String(format: "%02hhx", $0) }.joined()
    }
}
