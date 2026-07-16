//  Copyright (c) 2019 Siemens AG. Licensed under the MIT License.
//
//  CommunicationManager.swift
//  Axoloty
//
//

import Foundation

/// Provides a set of predefined communication events to transfer Coaty objects
/// between distributed Coaty agents based on the publish-subscribe API of a
/// `CommunicationClient`.
@MainActor
public class CommunicationManager {
    internal enum MessagePayload {
        case stringPayload(String)
        case bytesArrayPayload([UInt8])
    }
    
    // MARK: - Logger.

    internal let log = LogManager.log

    // MARK: - Properties.

    private var isDisposed = false
    internal var lifecycleTasks: [_Concurrency.Task<Void, Never>] = []

    /// Gets the namespace for communication as specified in the configuration
    /// options. Returns the default namespace used, if no namespace has been
    /// specified in configuration options.
    private(set) public var namespace: String

    internal var communicationOptions: CommunicationOptions
    internal var commonOptions: CommonOptions?
    
    // Container identity for public and internal use.
    public var identity: Identity

    /// The operating state of the communication manager.
    internal private(set) var operatingState: OperatingState = .stopped

    /// Communication state mirrored from the underlying transport.
    internal private(set) var communicationState: CommunicationState = .offline

    /// The async event hub shared by the underlying communication client.
    ///
    /// Use this hub together with the ``CommunicationEventHubKeys`` helpers to
    /// register streams for transport-level state and raw MQTT messages, or
    /// use the convenience accessors ``observeCommunicationStateStream()`` and
    /// ``observeRawMQTTMessageStream()``.
    public var eventHub: EventHub {
        return client.eventHub
    }

    /// Holds deferred publications (topic, payload) while the communication manager is offline.
    private var deferredPublications = [(String, MessagePayload)]()

    /// Ids of all advertised components that should be deadvertised on disconnection.
    internal var deadvertiseIds = [CoatyUUID]()

    /// The communication client that offers the required publisher-subscriber API.
    internal var client: CommunicationClient!

    /// Actor-owned lifecycle state for communication topic subscriptions.
    internal var subscriptionCoordinator: CommunicationSubscriptionCoordinator!
    
    // MARK: IORouting properties.
    
    /// IO state observables for own IO sources and actors (mapped by IO point ID).
    /// Key: CoatyUUID string, Value: IoStateItem
    internal var observedIoStateItems: [String: IoStateItem] = [:]

    /// Async IO value streams for own IO actors (mapped by IO actor ID).
    internal var observedIoValueItems: [String: UUID] = [:]

    /// Own IO sources with associating route, actor ids, and updateRate (mapped
    /// by IO source ID).
    /// Key: CoatyUUID string, Value: IoSourceItem
    internal var ioSourceItems: [String: IoSourceItem] = [:]

    /// Own IO actors with associated source ids (mapped by associating route).
    ///
    /// Key: route, Value: `MutableDictionaryBox` of: Key: CoatyUUID string
    /// (IO actor ID), Value: `MutableArrayBox` of CoatyUUID (IO source IDs).
    ///
    /// - Note: the nested collections are `MutableDictionaryBox`/
    ///   `MutableArrayBox` (small reference-type boxes, see
    ///   `Common/MutableBox.swift`) rather than native `Dictionary`/`Array`.
    ///   `associateIoActorItems`/`disassociateIoActorItems` (and
    ///   `CM+Observe.swift`) fetch these nested collections via subscript
    ///   and mutate them in place, relying on reference semantics for the
    ///   change to be visible through this outer dictionary without an
    ///   explicit write-back. A native (value-type) Swift collection would
    ///   silently drop those mutations. This used to be nested
    ///   `NSMutableDictionary`/`NSMutableArray` for the same reason (T-001).
    internal var ioActorItems: [String: MutableDictionaryBox<String, MutableArrayBox<CoatyUUID>>] = [:]
    
    /// The transport-level IO value stream is routed through ``EventHub``.
    
    /// Associated IONodes.
    internal var ioNodes: [IoNode] = []

    // MARK: - Initializers.

    public convenience init(identity: Identity, communicationOptions: CommunicationOptions, commonOptions: CommonOptions?) {
        self.init(
            identity: identity,
            communicationOptions: communicationOptions,
            commonOptions: commonOptions,
            client: nil
        )
    }

    internal init(
        identity: Identity,
        communicationOptions: CommunicationOptions,
        commonOptions: CommonOptions?,
        client: CommunicationClient?
    ) {
        self.identity = identity
        self.communicationOptions = communicationOptions
        self.commonOptions = commonOptions
        self.namespace = communicationOptions.namespace ?? DEFAULT_NAMESPACE
        // Fail-fast invariant, not user input.
        // swiftlint:disable:next force_try
        try! initializeNamespace()
        
        let mqttClientOptions = self.communicationOptions.mqttClientOptions!
        initializeMQTTClientId(mqttClientOptions)

        self.client = client ?? MQTTNIOClient(mqttClientOptions: mqttClientOptions, delegate: self)
        self.client.delegate = self

        let dispatcher = CommunicationSubscriptionCommandDispatcher(client: self.client)
        self.subscriptionCoordinator = CommunicationSubscriptionCoordinator(
            throwingCommandSink: { command in
                try await dispatcher.deliver(command)
            }
        )
        
        setupOperatingStateLogging()
        setupCommunicationStateLogging()
        setupSubscriptionStateHandler()
        setupOnConnectHandler()
        
        // Fail-fast invariant, not user input.
        // swiftlint:disable:next force_try
        try! self._initIoNodes()
        
        if self.communicationOptions.shouldAutoStart && !mqttClientOptions.shouldTryMDNSDiscovery {
            self.didReceiveStart()
        }
    }

    // MARK: - Manager lifecycle methods.

    /// Starts this communication manager with the communication options
    /// specified in the configuration. This is a noop if the communication
    /// manager has already been started.
    public func start() {
        // Fail-fast invariant, not user input.
        // swiftlint:disable:next force_try
        guard self.operatingState != OperatingState.started else {
            return
        }
        startClient()
    }

    /// Starts the communication client and waits until the desired
    /// subscriptions have been delivered to the broker.
    ///
    /// - Throws: A transport error when a subscription command cannot be
    ///   acknowledged, or a runtime error if the state stream terminates before
    ///   the client becomes online.
    @MainActor
    internal func startAndWaitUntilReady() async throws {
        let stateStream = await observeCommunicationStateStream()
        var iterator = stateStream.makeAsyncIterator()
        start()

        while let state = await iterator.next() {
            guard state == .online else {
                continue
            }

            let coordinator = self.subscriptionCoordinator!
            await coordinator.setOnline(true)
            await coordinator.activateDesiredTopics()
            if let error = await coordinator.takeCommandError() {
                throw error
            }
            return
        }

        throw AxolotyError.RuntimeError(
            "Communication state stream terminated before the client became online."
        )
    }

    /// Stops dispatching and emitting communication events and disconnects from
    /// the communication infrastructure.
    ///
    /// To continue processing with this communication manager sometime later,
    /// invoke `start()`.
    public func stop() {
        endClient()
    }

    /// Unsubscribe and disconnect from the communication binding.
    public func onDispose() {
        if isDisposed {
            return
        }

        isDisposed = true

        endClient()
    }

    /// Starts the client gracefully and tries to connect to the broker.
    private func startClient() {
        // Reinitialize potentially changed options in case of a restart.
        let mqttClientOptions = self.communicationOptions.mqttClientOptions!
        initializeMQTTClientId(mqttClientOptions)
        // Fail-fast invariant, not user input.
        // swiftlint:disable:next force_try
        try! initializeNamespace()
        // Fail-fast invariant, not user input.
        // swiftlint:disable:next force_try
        try! _initIoNodes()
        initializeDeadvertisements()
        
        // Listen to Associate events published by IO Routers.
        _observeAssociate()
        // Listen to Discover events for IoNodes.
        observeDiscoverIoNodes()
        // Listen to Discover events for Identity.
        observeDiscoverIdentity()
        
        let lastWill = self.getLastWill()
        self.client.connect(lastWillTopic: lastWill.topic, lastWillMessage: lastWill.msg)
        updateOperatingState(.started)
    }

    /// Gracefully ends the client.
    /// - NOTE: This triggers explicit identity deadvertisements.
    private func endClient() {
        // Gracefully send deadvertise messages to others.
        // NOTE: This does not change or adjust the last will.
        deadvertiseIdentity()

        self.unobserveIoStateAndValue()
        
        lifecycleTasks.forEach { $0.cancel() }
        lifecycleTasks.removeAll()
        self.client.disconnect()
        self.deferredPublications = []
        self.deadvertiseIds = []
        let coordinator = self.subscriptionCoordinator!
        _Concurrency.Task {
            await coordinator.setOnline(false)
            await coordinator.reset()
        }
        updateOperatingState(.stopped)
    }

    // MARK: - Setup methods.

    private func initializeMQTTClientId(_ mqttClientOptions: MQTTClientOptions) {
        // Assign a valid client id according to MQTT Spec 3.1:
        // The Server MUST allow ClientIds which are between 1 and 23 UTF-8 encoded 
        // bytes in length, and that contain only the characters
        // "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".
        // The Server MAY allow ClientId’s that contain more than 23 encoded bytes.
        // The Server MAY allow ClientId’s that contain characters not included in the list given above. 
        let id = self.identity.objectId.string
        mqttClientOptions.clientId = "Coaty" + String(id.replacingOccurrences(of: "-", with: "").prefix(18))
    }

    private func initializeNamespace() throws {
        var ns = self.communicationOptions.namespace
        
        if ns == "" || ns == nil {
            ns = DEFAULT_NAMESPACE
        }
        
        guard CommunicationTopic.isValidEventTypeFilter(filter: ns!) else {
            throw AxolotyError.InvalidConfiguration("CommunicationOptions.namespace contains invalid characters")
        }
        
        self.namespace = ns!
    }

    private func initializeDeadvertisements() {
        // Make sure the identity is added to the deadvertiseIds array in order to
        // send out a correct last will message.
        deadvertiseIds.append(self.identity.objectId)
        
        // Deadvertise IO nodes when unjoining.
        self.ioNodes.forEach { ioNode in
            deadvertiseIds.append(ioNode.objectId)
        }
    }

    /// Setup for the handler method that is invoked when the communication state of the client changes to online.
    private func setupOnConnectHandler() {}

    private func setupOperatingStateLogging() {}

    private func setupCommunicationStateLogging() {}

    private func setupSubscriptionStateHandler() {}

    /// Gets last will message to be published when the connection terminates
    /// abnormally.
    private func getLastWill() -> (topic: String, msg: String) {
        let lastWillTopic = CommunicationTopic.createTopicStringByLevelsForPublish(namespace: self.namespace, sourceId: self.identity.objectId, eventType: .Deadvertise)
        let deadvertiseEvent = DeadvertiseEvent.with(objectIds: deadvertiseIds)

        deadvertiseEvent.sourceId = self.identity.objectId

        return (lastWillTopic, deadvertiseEvent.json)
    }

    // MARK: - Identity and IoNodes lifecycle management.

    private func advertiseIdentity() {
        // Advertise identity once.
        // (cp. CommunicationManager.observeDiscoverIdentity)
        // Fail-fast invariant, not user input.
        // swiftlint:disable:next force_try
        try! publishAdvertise(AdvertiseEvent.with(object: self.identity))
    }
    
    private func advertiseIoNodes() {
        // Advertise IO nodes when joining (cp. _observeDiscoverIoNodes).
        self.ioNodes.forEach { ioNode in
            try? self.publishAdvertise(AdvertiseEvent.with(object: ioNode))
        }
    }

    private func deadvertiseIdentity() {
        publishDeadvertise(DeadvertiseEvent.with(objectIds: deadvertiseIds))
    }

    private func observeDiscoverIdentity() {
        let task = _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await self.observeDiscoverStream()
            for await event in stream {
                guard (event.coreTypes?.contains(.Identity) == true) ||
                      (event.objectId == self.identity.objectId.string) else { continue }
                guard event.sourceId != nil,
                      let correlationId = event.correlationId else { continue }
                let resolve = ResolveEvent.with(object: self.identity)
                self.publishResolve(event: resolve, correlationId: correlationId)
            }
        }
        lifecycleTasks.append(task)
    }

    // MARK: - Communication methods.

    /// Acquires a reference to a topic subscription.
    ///
    /// - Parameter topic: topic name.
    @MainActor
    internal func acquireSubscription(topic: String) async {
        let coordinator = self.subscriptionCoordinator!
        await coordinator.acquire(topic: topic)
    }

    /// Releases a reference to a topic subscription.
    ///
    /// - Parameter topic: topic name.
    @MainActor
    internal func releaseSubscription(topic: String) async {
        let coordinator = self.subscriptionCoordinator!
        await coordinator.release(topic: topic)
    }

    /// Schedules acquisition of a topic subscription for legacy synchronous
    /// internal call sites during the migration to async event streams.
    ///
    /// - Parameter topic: topic name.
    internal func subscribe(topic: String) {
        let coordinator = self.subscriptionCoordinator!
        _Concurrency.Task {
            await coordinator.acquire(topic: topic)
        }
    }

    internal func unsubscribe(topic: String) {
        let coordinator = self.subscriptionCoordinator!
        _Concurrency.Task {
            await coordinator.release(topic: topic)
        }
    }

    /// Publish defers publications until the communication manager comes online.
    ///
    /// - Parameters:
    ///   - topic: the publication topic.
    ///   - message: the payload message as String.
    internal func publish(topic: String, message: String) {
        // Fail-fast invariant, not user input.
        // swiftlint:disable:next force_try
        if self.communicationState == .offline {
            self.deferredPublications.append((topic, MessagePayload.stringPayload(message)))
        } else {
            // Attempt to publish. If we are disconnecting, this will fail silently.
            client.publish(topic, message: message)
        }
    }
    
    /// Publish defers publications until the communication manager comes online.
    ///
    /// - Parameters:
    ///   - topic: the publication topic.
    ///   - message: the payload message as Bytes array.
    internal func publish(topic: String, message: [UInt8]) {
        // Fail-fast invariant, not user input.
        // swiftlint:disable:next force_try
        if self.communicationState == .offline {
            self.deferredPublications.append((topic, MessagePayload.bytesArrayPayload(message)))
        } else {
            // Attempt to publish. If we are disconnecting, this will fail silently.
            client.publish(topic, message: message)
        }
    }

    /// Convenience setter for the operating state.
    private func updateOperatingState(_ state: OperatingState) {
        self.operatingState = state
        self.log.debug("Operating State: \(String(describing: state))")
        let eventHub = client.eventHub
        _Concurrency.Task {
            await eventHub.yieldState(value: state, to: CommunicationEventHubKeys.operatingState)
        }
    }

    nonisolated func didUpdateCommunicationState(_ state: CommunicationState) {
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            self.communicationState = state
            self.log.info("Communication State: \(String(describing: state))")
            await self.subscriptionCoordinator?.setOnline(state == .online)
            if state == .online {
                self.advertiseIdentity()
                self.advertiseIoNodes()
                self.deferredPublications.forEach { topic, payload in
                    switch payload {
                    case .bytesArrayPayload(let bytes): self.client.publish(topic, message: bytes)
                    case .stringPayload(let string): self.client.publish(topic, message: string)
                    }
                }
                self.deferredPublications.removeAll()
            }
        }
    }

    nonisolated func didReceiveRawMQTTMessage(topic: String, payload: [UInt8]) {
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            await self.eventHub.yield(value: RawMQTTMessage(topic: topic, payload: payload), to: CommunicationEventHubKeys.rawMQTTMessage)
        }
    }

    nonisolated func didReceiveIoValue(topic: String, payload: [UInt8]) {
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            await self.eventHub.yield(value: IoValueEventSnapshot(topic: topic, payload: payload), to: CommunicationEventHubKeys.ioValue)
        }
    }

    nonisolated func didReceiveMessage(topic: String, payload: String) {
        // Parsed messages are emitted directly by the transport's EventHub.
    }
    
    // MARK: - IO Routing
    
    private func _initIoNodes() throws {
        // Set up IO Nodes.
        if let ioNodesConfig = self.commonOptions?.ioContextNodes, !ioNodesConfig.isEmpty {
            self.ioNodes = try ioNodesConfig.keys.filter({ contextName -> Bool in
                if CommunicationTopic.isValidEventTypeFilter(filter: contextName) {
                    return true
                } else {
                    throw AxolotyError.InvalidConfiguration("ioContextName \(contextName) in ioContextNodes contains invalid characters")
                }
            }).map({ contextName -> IoNode in
                // Force unwrapping is safe.
                let ioNodeConfig = ioNodesConfig[contextName]!
                
                return IoNode(coreType: .IoNode,
                              objectType: CoreType.IoNode.objectType,
                              objectId: .init(),
                              name: contextName,
                              ioSources: ioNodeConfig.ioSources ?? [],
                              ioActors: ioNodeConfig.ioActors ?? [],
                              characteristics: ioNodeConfig.characteristics)
            }).filter({ node -> Bool in
                node.ioSources.count > 0 || node.ioActors.count > 0
            })
        }
    }
    
    /// Gets the IO node for the given IO context name, as configured in the
    /// configuration common options.
    ///
    /// Returns `nil` if no IO node is configured for the context name.
    public func getIoNodeByContext(contextName: String) -> IoNode? {
        return self.ioNodes.first { ioNode -> Bool in
            return ioNode.name == contextName
        }
    }
    
    /// Creates a new IO route for routing IO values of the given IO source to associated IO
    /// actors.
    ///
    /// This method is called by IO routers to associate IO sources with IO actors. An IO
    /// source publishes IO values on this route; an associated IO actor observes this route
    /// to receive these values.
    ///
    /// - Parameter ioSource: the IO source object
    /// - Returns: an associating topic for routing IO values
    public func createIoRoute(ioSource: IoSource) -> String {
        return CommunicationTopic.createTopicStringByLevelsForPublish(namespace: self.namespace, sourceId: ioSource.objectId, eventType: .IoValue)
    }

    internal func findIoPointById(objectId: CoatyUUID) -> IoPoint? {
        for ioNode in self.ioNodes {
            if let source = (ioNode.ioSources.first { $0.objectId == objectId }) {
                return source
            } else if let actor = (ioNode.ioActors.first { $0.objectId == objectId }) {
                return actor
            }
        }
        return nil
    }
    
    internal func handleAssociate(event: AssociateEvent) {
        let ioSourceId = event.data.ioSourceId
        let ioActorId = event.data.ioActorId
        let ioActor = self.findIoPointById(objectId: ioActorId) as? IoActor
        let isIoSourceAssociated = self.findIoPointById(objectId: ioSourceId) != nil
        let isIoActorAssociated = ioActor != nil

        if !isIoSourceAssociated && !isIoActorAssociated {
            return
        }

        let ioRoute = event.data.associatingRoute

        // Update own IO source associations
        if isIoSourceAssociated {
            self.updateIoSourceItems(ioSourceId: ioSourceId, ioActorId: ioActorId, ioRoute: ioRoute, updateRate: event.data.updateRate)
        }

        // Update own IO actor associations
        if isIoActorAssociated {
            if let ioRoute = ioRoute {
                self.associateIoActorItems(ioSourceId: ioSourceId, ioActor: ioActor!, ioRoute: ioRoute, isExternalRoute: event.data.isExternalRoute!)
            } else {
                self.disassociateIoActorItems(ioSourceId: ioSourceId, ioActorId: ioActorId, currentIoRoute: nil, newIoRoute: nil)
            }
        }

        // Dispatch IO state events to associated observables
        if isIoSourceAssociated {
            if let item = self.observedIoStateItems[ioSourceId.string] {
                let items = self.ioSourceItems[ioSourceId.string]

                let hasAssociations = (items != nil) && (items!.actorIds.count != 0)
                let updateRate: Int? = (items != nil) ? items!.updateRate : nil
                
                self.dispatchIoState(ioPointId: ioSourceId, item: item,
                                    message: IoStateEvent.with(hasAssociations: hasAssociations, updateRate: updateRate))
            }
        }

        if isIoActorAssociated {
            if let item = self.observedIoStateItems[ioActorId.string] {
                var actorIds: MutableDictionaryBox<String, MutableArrayBox<CoatyUUID>>?
                if let ioRoute = ioRoute {
                    actorIds = self.ioActorItems[ioRoute]
                }

                let sourceCount = actorIds?[ioActorId.string]?.count ?? 0
                self.dispatchIoState(ioPointId: ioActorId, item: item,
                                    message: IoStateEvent.with(hasAssociations: sourceCount > 0))
            }
        }
    }
    
    private func updateIoSourceItems(ioSourceId: CoatyUUID, ioActorId: CoatyUUID, ioRoute: String?, updateRate: Int?) {
        if let ioRoute = ioRoute {
            if self.ioSourceItems[ioSourceId.string] == nil {
                let items = IoSourceItem(associatingRoute: ioRoute, actorsIds: [ioActorId], updateRate: updateRate)
                self.ioSourceItems[ioSourceId.string] = items
            } else if let items = self.ioSourceItems[ioSourceId.string] {
                if items.associatingRoute == ioRoute {
                    if items.actorIds.firstIndex(of: ioActorId) == nil {
                        items.actorIds.append(ioActorId)
                    }
                } else {
                    // Disassociate current IO actors due to a route change.
                    let previousRoute = items.associatingRoute
                    items.associatingRoute = ioRoute
                    items.actorIds.forEach { actorId in
                        self.disassociateIoActorItems(ioSourceId: ioSourceId, ioActorId: actorId, currentIoRoute: previousRoute, newIoRoute: nil)
                    }
                    items.actorIds = [ioActorId]
                }
                items.updateRate = updateRate
            }
        } else {
            if let items = self.ioSourceItems[ioSourceId.string] {
                let i = items.actorIds.firstIndex(of: ioActorId)
                if let i = i {
                    items.actorIds.remove(at: i)
                }
                items.updateRate = updateRate
                if items.actorIds.isEmpty {
                    self.ioSourceItems.removeValue(forKey: ioSourceId.string)
                }
            }
        }
    }
    
    private func associateIoActorItems(ioSourceId: CoatyUUID, ioActor: IoActor, ioRoute: String, isExternalRoute: Bool) {
        let ioActorId = ioActor.objectId

        // Disassociate any active association for the given IO source and IO actor.
        self.disassociateIoActorItems(ioSourceId: ioSourceId, ioActorId: ioActorId, currentIoRoute: nil, newIoRoute: ioRoute)

        if let items = self.ioActorItems[ioRoute] {
            if let sourceIds = items[ioActorId.string] {
                if !sourceIds.contains(ioSourceId) {
                    sourceIds.append(ioSourceId)
                }
            } else {
                items[ioActorId.string] = MutableArrayBox([ioSourceId])
            }
        } else {
            let newItems = MutableDictionaryBox<String, MutableArrayBox<CoatyUUID>>()
            newItems[ioActorId.string] = MutableArrayBox([ioSourceId])
            self.ioActorItems[ioRoute] = newItems
            self.subscribe(topic: ioRoute)
        }
    }

    private func disassociateIoActorItems(ioSourceId: CoatyUUID, ioActorId: CoatyUUID, currentIoRoute: String?, newIoRoute: String?) {
        var ioRoutesToUnsubscribe: [String] = []
        let handler = { (items: MutableDictionaryBox<String, MutableArrayBox<CoatyUUID>>, route: String) in
            if let newIoRoute = newIoRoute, newIoRoute == route {
                return
            }
            if let sourceIds = items[ioActorId.string] {
                sourceIds.remove(ioSourceId)
                if sourceIds.count == 0 {
                    items.removeValue(forKey: ioActorId.string)
                }
                if items.count == 0 {
                    ioRoutesToUnsubscribe.append(route)
                }
            }
        }

        if let currentIoRoute = currentIoRoute {
            if let items = self.ioActorItems[currentIoRoute] {
                handler(items, currentIoRoute)
            }
        } else {
            self.ioActorItems.forEach { route, items in
                handler(items, route)
            }
        }

        ioRoutesToUnsubscribe.forEach { route in
            self.ioActorItems.removeValue(forKey: route)
            self.unsubscribe(topic: route)
        }
    }
    
    private func unobserveIoStateAndValue() {
        // Dispatch IO state events to all IO state observers.
        self.observedIoStateItems.forEach { _, item in
            self.dispatchIoState(ioPointId: item.ioPointId, item: item,
                                message: IoStateEvent.with(hasAssociations: false, updateRate: nil))

            // Ensure subscriptions on IO state observables are unsubscribed automatically.
            item.dispatchComplete()
        }

        // Clean up the current IO routes of all IO actors.
        self.ioActorItems.forEach { ioRoute, _ in
            self.unsubscribe(topic: ioRoute)
        }

        // Ensure subscriptions on IO value item observables are unsubscribed automatically.
        self.observedIoValueItems.removeAll()
    }

    private func dispatchIoState(ioPointId: CoatyUUID, item: IoStateItem, message: IoStateEvent) {
        item.dispatchNext(message: message)
        let snapshot = IoStateEventSnapshot(
            ioPointId: ioPointId.string,
            hasAssociations: message.eventData.hasAssociations(),
            updateRate: message.eventData.updateRate()
        )
        let eventHub = client.eventHub
        let stateKey = CommunicationEventHubKeys.ioState(ioPointId: ioPointId.string)
        _Concurrency.Task {
            await eventHub.yieldState(
                value: snapshot,
                to: stateKey
            )
        }
    }
}

extension CommunicationManager: CommunicationClientDelegate {

    /// Auto start communication manager (caused by shouldAutoStart option or
    /// bonjour discovery).
    nonisolated func didReceiveStart() {
        _Concurrency.Task { @MainActor [weak self] in
            self?.start()
        }
    }
}

class IoStateItem {
    let ioPointId: CoatyUUID
    var currentValue: IoStateEvent
    
    init(ioPointId: CoatyUUID, initialValue: IoStateEvent) {
        self.ioPointId = ioPointId
        self.currentValue = initialValue
    }
    
    func dispatchNext(message: IoStateEvent) {
        self.currentValue = message
    }
    
    func dispatchComplete() {
    }
}

/// Convenience class use by class attribute `IoSourceItems`
internal class IoSourceItem {
    var associatingRoute: String
    
    var actorIds: [CoatyUUID]
    
    var updateRate: Int?
    
    init(associatingRoute: String, actorsIds: [CoatyUUID], updateRate: Int?) {
        self.associatingRoute = associatingRoute
        self.actorIds = actorsIds
        self.updateRate = updateRate
    }
}
