import Testing
import AxolotyCoatyModels

@Test("the retained CoatyObject compatibility schema is valid")
func coatyObjectSchemaValidates() throws {
    try CoatyObject.schema.validate()
    #expect(CoatyObject.schema.coreType == .coatyObject)
}
