// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import Axoloty

@Suite
struct ConfigurationBuilderTests {
    @Test
    func testBuildSucceedsWithCommunicationOnly() throws {
        let communication = CommunicationOptions()
        let configuration = try Configuration.build { builder in
            builder.communication = communication
        }

        #expect(configuration.common == nil)
        #expect(configuration.communication === communication)
        #expect(configuration.controllers == nil)
        #expect(configuration.databases == nil)
    }

    @Test
    func testBuildPreservesCommonControllersAndDatabases() throws {
        let common = CommonOptions()
        let communication = CommunicationOptions()
        let controllers = ControllerConfig(controllerOptions: [:])
        let databases = DatabaseOptions(databaseConnections: [:])

        let configuration = try Configuration.build { builder in
            builder.common = common
            builder.communication = communication
            builder.controllers = controllers
            builder.databases = databases
        }

        #expect(configuration.common === common)
        #expect(configuration.communication === communication)
        #expect(configuration.controllers === controllers)
        #expect(configuration.databases === databases)
    }

    @Test
    func testBuildThrowsInvalidConfigurationWhenCommunicationMissing() {
        do {
            _ = try Configuration.build { _ in }
            Issue.record("Expected Configuration.build to throw when communication is missing")
        } catch let error as AxolotyError {
            guard case .invalidConfiguration = error else {
                Issue.record("Expected .invalidConfiguration, got \(error)")
                return
            }
            #expect(error.userFriendlyMessage == "communication: Configuration.build requires communication options to be set")
        } catch {
            Issue.record("Expected AxolotyError, got \(error)")
        }
    }
}
