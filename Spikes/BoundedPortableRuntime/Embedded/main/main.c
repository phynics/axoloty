// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#include "esp_system.h"
#include "BridgingHeader.h"

void app_main(void) {
    // Keep the probe reachable so the cross-build includes its specializations.
    bounded_portable_runtime_probe();
}
