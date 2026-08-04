//===----------------------------------------------------------------------===//
// Copyright 2026 container-engine-api project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import ContainerEngineService
import Darwin
import Foundation

@main
struct ContainerEngineServiceExecutable {
    static func main() async {
        do {
            try await ContainerEngineServiceRunner.run(
                arguments: Array(CommandLine.arguments.dropFirst())
            )
        } catch {
            FileHandle.standardError.write(
                Data("container-engine: \(error)\n".utf8)
            )
            Foundation.exit(EXIT_FAILURE)
        }
    }
}
