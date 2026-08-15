// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
//
//  PolygonTests.swift
//  Axoloty

@testable import Axoloty
import Foundation
import Testing

/// Regression tests for the GeoJSON `Polygon` model.
///
/// Issue #445 / P1-2: `Polygon.init(coordinates:)` assigned `self.coordinates
/// = []`, silently discarding its argument. Any polygon constructed with
/// coordinates would encode with no rings and never survive a round trip.
@Suite
struct PolygonTests {

    @Test
    func initPreservesProvidedCoordinates() {
        let coordinates: [[Position]] = [
            [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 0.0]]
        ]
        let polygon = Polygon(coordinates: coordinates)
        #expect(polygon.type == .Polygon)
        #expect(polygon.coordinates == coordinates)
        #expect(polygon.coordinates.count == 1)
        #expect(polygon.coordinates[0].count == 4)
    }

    @Test
    func initPreservesEmptyCoordinates() {
        let polygon = Polygon(coordinates: [])
        #expect(polygon.type == .Polygon)
        #expect(polygon.coordinates == [])
    }

    @Test
    func initPreservesMultipleRingsAndPositions() {
        let outer: Position = [0.0, 0.0]
        let inner: Position = [0.2, 0.2]
        let coordinates: [[Position]] = [
            [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 0.0]],
            [[0.2, 0.2], [0.8, 0.2], [0.8, 0.8], [0.2, 0.2]],
        ]
        let polygon = Polygon(coordinates: coordinates)
        #expect(polygon.coordinates == coordinates)
        #expect(polygon.coordinates[0].first == outer)
        #expect(polygon.coordinates[1].first == inner)
    }

    @Test
    func initPreservesBBoxDefault() {
        let polygon = Polygon(coordinates: [[[0.0, 0.0], [1.0, 1.0]]])
        #expect(polygon.bbox == nil)
    }

    /// Encode → decode must preserve the coordinates handed to the
    /// initializer (the wire-visible consequence of P1-2).
    @Test
    func encodeDecodeRoundTripPreservesCoordinates() throws {
        let coordinates: [[Position]] = [
            [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0], [0.0, 0.0]]
        ]
        let polygon = Polygon(coordinates: coordinates)
        let data = try JSONEncoder().encode(polygon)
        let decoded = try JSONDecoder().decode(Polygon.self, from: data)

        #expect(decoded.type == .Polygon)
        #expect(decoded.coordinates.count == 1)
        #expect(decoded.coordinates == coordinates)
    }
}