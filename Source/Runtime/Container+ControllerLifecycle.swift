// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@MainActor
final class ContainerControllerLifecycle {
    private final class ControllerState {
        let controller: Controller
        var isPrepared = false
        var isActive = false
        var preparationTask: Task<Void, Never>?

        init(controller: Controller) {
            self.controller = controller
        }
    }

    private var states = [ObjectIdentifier: ControllerState]()
    private var operatingState: OperatingState = .stopped
    private var hasObservedOperatingState = false
    private var isShutdown = false

    func register(_ controller: Controller, operatingState: OperatingState) {
        guard !self.isShutdown else { return }

        let state = ControllerState(controller: controller)
        self.states[ObjectIdentifier(controller)] = state
        self.operatingState = operatingState
        if operatingState == .started {
            self.scheduleActivation(for: state)
        }
    }

    func prepareControllers() async -> [Controller] {
        while !self.isShutdown {
            let currentStates = Array(self.states.values)
            for state in currentStates {
                await self.prepare(state)
            }

            guard currentStates.count == self.states.count,
                  self.states.values.allSatisfy(\.isPrepared) else {
                continue
            }
            return self.states.values.map(\.controller)
        }

        return self.states.values.map(\.controller)
    }

    func handleOperatingState(_ state: OperatingState) async {
        guard !self.isShutdown else { return }

        self.operatingState = state
        if !self.hasObservedOperatingState {
            self.hasObservedOperatingState = true
            if state == .stopped {
                self.states.values.forEach { $0.isActive = false }
                return
            }
        }

        switch state {
        case .started:
            for controllerState in Array(self.states.values) {
                await self.activate(controllerState)
            }
        case .stopped:
            for controllerState in Array(self.states.values) {
                controllerState.isActive = false
                controllerState.controller.onCommunicationManagerStopping()
            }
        }
    }

    func shutdown() {
        self.isShutdown = true
        for state in self.states.values {
            state.preparationTask?.cancel()
            state.preparationTask = nil
        }
        self.states.removeAll()
    }

    private func prepare(_ state: ControllerState) async {
        guard !self.isShutdown, !state.isPrepared else { return }

        if let preparationTask = state.preparationTask {
            await preparationTask.value
            return
        }

        let controller = state.controller
        let preparationTask = Task { @MainActor in
            await controller.prepareForCommunication()
            state.isPrepared = true
        }
        state.preparationTask = preparationTask
        await preparationTask.value
        state.preparationTask = nil
    }

    private func scheduleActivation(for state: ControllerState) {
        let controllerId = ObjectIdentifier(state.controller)
        Task { @MainActor [weak self] in
            guard let self,
                  let state = self.states[controllerId] else {
                return
            }
            await self.activate(state)
        }
    }

    private func activate(_ state: ControllerState) async {
        guard !self.isShutdown,
              self.operatingState == .started,
              state.controller.communicationManager?.operatingState == .started,
              !state.isActive else {
            return
        }

        await self.prepare(state)

        guard !self.isShutdown,
              self.operatingState == .started,
              state.controller.communicationManager?.operatingState == .started,
              state.isPrepared,
              !state.isActive else {
            return
        }

        state.isActive = true
        state.controller.onCommunicationManagerStarting()
    }
}
