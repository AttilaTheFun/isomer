// Compact spec-string forms of the overlay types for the FFI bridges
// (swift_ffi carries strings and scalars; hand-rolled split parsing keeps
// the core Foundation-free and the hosts JSON-encoder-free).
//
// Annotations — records ";"-separated, fields "|"-separated:
//   id|latitude|longitude|red|green|blue|alpha|radius[|title]
// (titles must not contain the separators; the optional 9th field keeps
// older 8-field specs parsing).
// Polygons — records newline-separated, fields "|"-separated:
//   id|fillR,fillG,fillB,fillA|strokeR,strokeG,strokeB,strokeA,width|lat,lon;lat,lon;…
// (an empty third field means no stroke).
// Polylines — records newline-separated, fields "|"-separated:
//   id|red,green,blue,alpha|width|lat,lon;lat,lon;…

enum MapOverlaySpec {
    static func parseAnnotations(_ spec: String) -> [MapAnnotation] {
        var annotations: [MapAnnotation] = []
        for record in spec.split(separator: ";") {
            let fields = record.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 8 || fields.count == 9,
                  let latitude = Double(fields[1]), let longitude = Double(fields[2]),
                  let red = Double(fields[3]), let green = Double(fields[4]),
                  let blue = Double(fields[5]), let alpha = Double(fields[6]),
                  let radius = Double(fields[7]) else {
                continue
            }
            annotations.append(
                MapAnnotation(
                    id: String(fields[0]),
                    coordinate: MapCoordinate(latitude: latitude, longitude: longitude),
                    color: MapColor(red: red, green: green, blue: blue, alpha: alpha),
                    radius: radius,
                    title: fields.count == 9 ? String(fields[8]) : ""
                )
            )
        }
        return annotations
    }

    static func parsePolylines(_ spec: String) -> [MapPolyline] {
        var polylines: [MapPolyline] = []
        for record in spec.split(separator: "\n") {
            let fields = record.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 4,
                  let color = parseColor(fields[1]),
                  let width = Double(fields[2]) else {
                continue
            }
            var coordinates: [MapCoordinate] = []
            for pair in fields[3].split(separator: ";") {
                let numbers = pair.split(separator: ",")
                guard numbers.count == 2,
                      let latitude = Double(numbers[0]), let longitude = Double(numbers[1]) else {
                    continue
                }
                coordinates.append(MapCoordinate(latitude: latitude, longitude: longitude))
            }
            guard coordinates.count >= 2 else { continue }
            polylines.append(MapPolyline(id: String(fields[0]), coordinates: coordinates, color: color, width: width))
        }
        return polylines
    }

    static func parsePolygons(_ spec: String) -> [MapPolygon] {
        var polygons: [MapPolygon] = []
        for record in spec.split(separator: "\n") {
            let fields = record.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 4, let fill = parseColor(fields[1]) else { continue }

            var strokeColor: MapColor?
            var strokeWidth = 2.0
            let strokeParts = fields[2].split(separator: ",")
            if strokeParts.count == 5,
               let red = Double(strokeParts[0]), let green = Double(strokeParts[1]),
               let blue = Double(strokeParts[2]), let alpha = Double(strokeParts[3]),
               let width = Double(strokeParts[4]) {
                strokeColor = MapColor(red: red, green: green, blue: blue, alpha: alpha)
                strokeWidth = width
            }

            var coordinates: [MapCoordinate] = []
            for pair in fields[3].split(separator: ";") {
                let numbers = pair.split(separator: ",")
                guard numbers.count == 2,
                      let latitude = Double(numbers[0]), let longitude = Double(numbers[1]) else {
                    continue
                }
                coordinates.append(MapCoordinate(latitude: latitude, longitude: longitude))
            }
            guard coordinates.count >= 3 else { continue }
            polygons.append(
                MapPolygon(
                    id: String(fields[0]),
                    coordinates: coordinates,
                    fillColor: fill,
                    strokeColor: strokeColor,
                    strokeWidth: strokeWidth
                )
            )
        }
        return polygons
    }

    private static func parseColor(_ field: Substring) -> MapColor? {
        let parts = field.split(separator: ",")
        guard parts.count == 4,
              let red = Double(parts[0]), let green = Double(parts[1]),
              let blue = Double(parts[2]), let alpha = Double(parts[3]) else {
            return nil
        }
        return MapColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}
