import Foundation

@main
struct SelectionSmoke {
static func main() {
let snowy = AssetRecord(
    id: "snowy",
    bundle: "bundle",
    relativePath: "snowy.icasset",
    metadataType: "activeScene",
    relevancyData: .object(["info": .array([.object(["weather": .object(["condition": .string("snowy")])])])]),
    sprites: [SpriteRecord(spriteType: "video", assetBaseName: "snowy", mediaFiles: ["snowy.mov"], plane: "centerpiece")],
    integrity: IntegrityRecord(valid: true)
)
let generic = AssetRecord(
    id: "generic",
    bundle: "bundle",
    relativePath: "generic.icasset",
    metadataType: "activeScene",
    relevancyData: .object(["info": .array([])]),
    sprites: [SpriteRecord(spriteType: "video", assetBaseName: "generic", mediaFiles: ["generic.mov"], plane: "centerpiece")],
    integrity: IntegrityRecord(valid: true)
)
var memory = SelectionMemory()
let chosen = SelectionEngine().choose(from: [generic, snowy], context: SelectionContext(weatherConditions: ["snowy"]), memory: &memory, seed: 1)
guard chosen?.id == "snowy" else { fatalError("selection smoke failed") }
let christmas = Calendar.current.date(from: DateComponents(year: 2026, month: 12, day: 25))!
guard SnoopyCalendarResolver.events(for: christmas).contains("christmas") else { fatalError("calendar smoke failed") }
print("selection smoke OK: \(chosen!.id)")
}
}
