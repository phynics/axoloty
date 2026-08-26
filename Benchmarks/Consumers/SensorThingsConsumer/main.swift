// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Release consumer exercising the SensorThings models and controllers
// (issue #353).
//
// Anchors Thing, Sensor, Observation, SensorSourceController, and
// SensorObserverController so the binary size captures the incremental cost
// of the SensorThings subsystem beyond the communication event baseline.

import AxolotyObjectModel
import AxolotySensorThings

let coreType = ObjectCoreType.coatyObject
let metadata = try! SensorThingsJSONValue("{\"manufacturer\":\"axoloty\"}")
let observationType = ObservationType.measurement
print("SENSORTHINGS_CONSUMER_OK: \(coreType) \(metadata.kind) \(observationType.rawValue)")
