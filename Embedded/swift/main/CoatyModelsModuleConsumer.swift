// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyCoatyModels

@inline(never)
func axoloty_coaty_models_embedded_link_probe() -> Bool {
    IoSource.schema.fieldCount == 5
}
