# ``Axoloty``

A [Coaty](https://coaty.io/) implementation written in Swift.

Axoloty provides a lightweight, object-oriented middleware for building
distributed IoT applications out of loosely coupled, decentralized *Coaty
agents* that communicate over an open publish-subscribe messaging protocol
(MQTT). Agents discover, distribute, share, query, and persist hierarchically
typed data using a platform-agnostic, extensible object model.

@Metadata {
    @TechnologyRoot
}

## Overview

A Coaty application is built around a ``Container`` that resolves components
and configuration, manages the lifecycle of its controllers, and mediates
communication with other agents through a ``CommunicationManager`` backed by
an MQTT broker.

The typical startup flow is:

1. Build a ``Configuration`` from ``CommonOptions`` and ``CommunicationOptions``
   (including ``MQTTClientOptions`` for broker connectivity).
2. Register application-specific controllers and object types in a
   ``Components`` instance.
3. Resolve a ``Container`` via ``Container.resolve(components:configuration:)``.
4. The container bootstraps the ``Runtime``, communication manager, and
   controllers; controllers then exchange ``CommunicationEvent``s over MQTT.

Error handling is unified through [ErrorKit](https://github.com/FlineDev/ErrorKit):
package-defined failures conform to `Throwable` and surface stable,
user-facing messages via ``AxolotyError``.

For a step-by-step introduction including a compiling minimal example, see
``GettingStarted``.

## Topics

### Runtime

- ``Container``
- ``Runtime``
- ``Configuration``
- ``ConfigurationBuilder``
- ``Components``
- ``Controller``

### Communication

- ``CommunicationManager``
- ``CommunicationEvent``
- ``CommunicationTopic``

### Configuration

- ``CommonOptions``
- ``CommunicationOptions``
- ``MQTTClientOptions``
- ``ControllerOptions``

### Errors

- ``AxolotyError``

### Logging

- ``LogManager``
- ``Subsystem``

### Articles

- ``GettingStarted``
- <doc:Logging-article>
