//  Copyright (c) 2019 Siemens AG. Licensed under the MIT License.
//
//  Container.swift
//  Axoloty
//

import ErrorKit
import Foundation

/// An IoC container that uses constructor dependency injection to create
/// container components and to resolve dependencies. This container defines the
/// entry and exit points for any Coaty application providing lifecycle
/// management for its components.
@MainActor
public class Container {
    
    // MARK: Attributes.
    
    /// Gets the identity object of this container.
    /// The identity can be initialized in the common configuration option
    /// `agentIdentity`.
    private(set) public var identity: Identity?

    /// Gets the runtime object of this container.
    private(set) public var runtime: Runtime?

    /// Gets the communication manager of this container.
    private(set) public var communicationManager: CommunicationManager?

    private var controllers = [String: Controller]()
    private var isShutdown = false
    private var operatingStateTask: _Concurrency.Task<Void, Never>?
    
    /// A dispatch queue handling controller synchronisation issues.
    private var queue: DispatchQueue!

    /// A queue ID needed to guarantee each container gets one dedicated queue __only__.
    private var queueID = "coatyswift.containerQueue." + UUID().uuidString

    /// Creates and bootstraps a Coaty container by registering and resolving the given components
    /// and configuratiuon options.
    ///
    /// - Parameters:
    ///   - components: the components to set up within this container
    ///   - configuration: the configuration options for the components
    public static func resolve(components: Components, configuration: Configuration) -> Container {
        
        // Adjust logging level for Axoloty.
        LogManager.logLevel = LogManager.getLogLevel(logLevel: configuration.common?.logLevel ?? AxolotyLogLevel.error)

        let container = Container()
        
        // Add container specific dispatch queue.
        container.queue = DispatchQueue(label: container.queueID)
        
        // Ensure all Coaty core object types are registered.
        CoreType.registerCoreObjectTypes()
        
        // Ensure all SensorThings object types are registered.
        CoreType.registerSensorThingsTypes()
        
        container.resolveComponents(components, configuration)
        return container
    }
    
    /// Dynamically registers and resolves the given controller class
    /// with the specified controller config options.
    /// The request is silently ignored if the container has already
    /// been shut down.
    ///
    /// - Parameters:
    ///     - name: the name of the controller class (must match the controller name
    ///             specified in controller config options)
    ///     - controllerType: the class type of the controller
    ///     - controllerOptions: the controller's configuration options. Defaults to
    ///       an empty `ControllerOptions()` when omitted, matching how statically
    ///       registered controllers without configured options are resolved.
    public func registerController(name: String, controllerType: Controller.Type, controllerOptions: ControllerOptions = ControllerOptions()) throws {
        if isShutdown {
            return
        }
            
        guard self.runtime != nil else {
            LogManager.log.error("Runtime was not initialized.")
            throw AxolotyError.invalidConfiguration(option: "runtime", reason: "was not initialized")
        }

        guard self.communicationManager != nil else {
            LogManager.log.error("CommunicationManager was not initialized.")
            throw AxolotyError.invalidConfiguration(option: "communicationManager", reason: "was not initialized")
        }

        if self.controllers[name] != nil {
            LogManager.log.error("Controller with given name already exists.")
            throw AxolotyError.invalidConfiguration(option: "name", reason: "controller with given name already exists")
        }

        let controller = resolveController(name: name, controllerType: controllerType, controllerOptions: controllerOptions)
        self.controllers[name] = controller
            
        controller.onInit()
            
            // Trigger onCommunicationManagerStarting() when a dynamically
            // registered controller joins an already-started manager.
        _Concurrency.Task { @MainActor [weak self, weak controller] in
                guard let self,
                      let controller,
                      let communicationManager = self.communicationManager else {
                    return
                }
                let stream = await communicationManager.observeOperatingStateStream()
                var iterator = await stream.makeAsyncIteratorAndWait()
                if await iterator.next() == .started {
                    self.dispatchOperatingState(state: .started, ctrl: controller)
                }
        }
    }
    
    /// Gets the registered controller of the given name.
    /// Returns nil if the controller class type is not registered.
    /// - Parameters:
    ///     - name: the name of the controller
    public func getController<C: Controller>(name: String) -> C? {
        return self.controllers[name] as? C
    }

    /// Prepares registered controllers, starts communication, and waits until
    /// their desired subscriptions are acknowledged by the broker.
    ///
    /// - Throws: A communication or subscription error reported during startup.
    public func startAndWaitUntilReady() async throws {
        let controllers = Array(self.controllers.values)
        for controller in controllers {
            await controller.prepareForCommunication()
        }

        guard let communicationManager else {
            throw AxolotyError.invalidConfiguration(option: "communicationManager", reason: "was not initialized")
        }

        try await communicationManager.startAndWaitUntilReady()
        for controller in controllers {
            await controller.onCommunicationManagerReady()
        }
    }
    
    /// Creates a new array with the results of calling the provided callback
    /// function once for each registered controller classType/classInstance
    /// pair.
    /// - Parameters:
    ///     - f: function that produces an element of the new array
    public func mapControllers<T>(_ f: (String, Controller) -> T) -> [T] {
        var mapResult = [T]()
        controllers.forEach { (name, controller) in
            let result = f(name, controller)
            mapResult.append(result)
        }
        
        return mapResult
    }
    
    /// The exit point for a Coaty applicaton.
    /// Releases all registered container components and its associated system resources.
    /// This container should no longer be used afterwards.
    public func shutdown() {
        if self.isShutdown {
            return
        }
        
        self.isShutdown = true
        self.releaseComponents()
    }
    
    private func resolveController(name: String, controllerType: Controller.Type, controllerOptions: ControllerOptions?) -> Controller {
        let controller = controllerType.init(container: self, options: controllerOptions, controllerType: name)
        return controller
    }
    
    private func registerCustomObjectTypes(_ components: Components) {
        for objectType in components.objectTypes {
            _ = objectType.objectType
        }
    }
    
    private func resolveComponents(_ components: Components, _ configuration: Configuration) {
        self.registerCustomObjectTypes(components)

        let identity: Identity
        do {
            identity = try createIdentity(options: configuration.common?.agentIdentity)
        } catch {
            LogManager.log.critical("Failed to create identity: \(ErrorKit.errorChainDescription(for: AxolotyError.caught(error)))")
            identity = Identity(name: "Coaty Agent")
        }
        self.identity = identity
        let runtime = Runtime(commonOptions: configuration.common, databaseOptions: configuration.databases)
        self.runtime = runtime
        
        // Create CommunicationManager.
        do {
            self.communicationManager = try CommunicationManager(
                identity: self.identity!,
                communicationOptions: configuration.communication,
                commonOptions: configuration.common
            )
        } catch {
            LogManager.log.critical("Failed to create CommunicationManager: \(ErrorKit.errorChainDescription(for: AxolotyError.caught(error)))")
        }

        // Create all controllers.
        components.controllers.forEach { (name, controllerType) in
            let options = configuration.controllers?.controllerOptions[name]
            let controller = resolveController(name: name, controllerType: controllerType, controllerOptions: options)
            self.controllers[name] = controller
        }
        
        // Finally call initialization lifecycle method of each controller.
        self.controllers.forEach { (_, controller) in
            controller.onInit()
        }
        
        // Observe operating state and dispatch to registered controllers.
        self.operatingStateTask = _Concurrency.Task { @MainActor [weak self] in
            guard let self,
                  let communicationManager = self.communicationManager else {
                return
            }
            let stream = await communicationManager.observeOperatingStateStream()
            var iterator = await stream.makeAsyncIteratorAndWait()
            var isInitialOperatingState = true
            while let state = await iterator.next() {
                if isInitialOperatingState {
                    isInitialOperatingState = false
                    if state == .stopped {
                        continue
                    }
                }
                for controller in self.controllers.values {
                    self.dispatchOperatingState(state: state, ctrl: controller)
                }
            }
        }

    }
    
    private func releaseComponents() {
        // Dispose Communication Manager first to trigger operating state changes
        communicationManager?.onDispose()
        self.controllers.forEach { (_, controller) in
            controller.onDispose()
        }

        self.operatingStateTask?.cancel()
        self.operatingStateTask = nil
        self.controllers = [String: Controller]()
        self.communicationManager = nil
        self.runtime = nil
        self.identity = nil
    }
    
    private func dispatchOperatingState(state: OperatingState, ctrl: Controller) {
        switch state {
        case OperatingState.started: 
            ctrl.onCommunicationManagerStarting()
        case OperatingState.stopped: 
            ctrl.onCommunicationManagerStopping()
        }
    }

    private func createIdentity(options: [String: Any]?) throws -> Identity {
        let identity = Identity(name: "Coaty Agent")

        // Merge property values from CommonOptions.agentIdentity option
        // ignoring coreType and objectType properties.
        if options != nil {
            for (key, value) in options! {
                switch key {
                    case "name":
                        guard let name = value as? String else {
                            throw AxolotyError.invalidConfiguration(option: "agentIdentity.name", reason: "must be a String")
                        }
                        identity.name = name
                    case "objectId":
                        guard let objectId = value as? CoatyUUID else {
                            throw AxolotyError.invalidConfiguration(option: "agentIdentity.objectId", reason: "must be a CoatyUUID")
                        }
                        identity.objectId = objectId
                    case "externalId":
                        identity.externalId = value as? String
                    case "parentObjectId":
                        identity.parentObjectId = value as? CoatyUUID
                    case "locationId":
                        identity.locationId = value as? CoatyUUID
                    case "isDeactivated":
                        identity.isDeactivated = value as? Bool
                    default:
                        break
                }
            }
        }

        return identity
    }
}
