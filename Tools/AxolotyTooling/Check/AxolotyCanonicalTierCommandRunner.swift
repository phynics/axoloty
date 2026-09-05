// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Preserves lifecycle-aware execution for the canonical integration node.
struct CanonicalTierCommandRunner: AxolotyLifecycleCommandRunning {
    let commandRunner: any AxolotyCheckCommandRunning
    let integrationRunner: any AxolotyIntegrationRunning

    func run(_ command: AxolotyCommandPlan) -> AxolotyCheckCommandResult {
        commandRunner.run(command)
    }

    func run(
        _ command: AxolotyCommandPlan,
        context: AxolotyCommandRunContext
    ) -> AxolotyCheckCommandResult {
        if context.node == "integration-tests" {
            if let boundedRunner = integrationRunner as? any AxolotyBoundedIntegrationRunning {
                return boundedRunner.run(timeoutSeconds: command.timeoutSeconds)
            }
            return integrationRunner.run()
        }
        if let lifecycleRunner = commandRunner as? any AxolotyLifecycleCommandRunning {
            return lifecycleRunner.run(command, context: context)
        }
        return commandRunner.run(command)
    }
}
