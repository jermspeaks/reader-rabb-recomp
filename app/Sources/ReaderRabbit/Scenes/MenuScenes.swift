import Foundation

/// Activity metadata in menu order (RRPW32.EXE tables 0x441ffc, 0x441b5c,
/// FUN_0041dad0, FUN_00418f81).
enum Activity: Int, CaseIterable {
    case countingClub = 0, abcDiner, shapeShack, patternParade

    var name: String {
        ["Counting Club", "ABC Diner", "Shape Shack", "Pattern Parade"][rawValue]
    }
    /// Exterior layout (COMB) and its background id.
    var exteriorComb: Int { [2498, 8321, 21882, 18055][rawValue] }
    var exteriorBackground: Int { [2400, 2200, 3500, 2800][rawValue] }
    /// Speech played when going from the main menu to the exterior.
    var toExteriorSpeech: Int { [21048, 21047, 21098, 21097][rawValue] }
    /// Speech played when entering the activity from its exterior.
    var enterSpeech: Int { [21060, 21070, 21057, 21069][rawValue] }
    /// Game background for the activity itself.
    var gameBackground: Int { [11000, 32687, 25000, 24408][rawValue] }
    /// Host introduction on the first visit to the exterior (table 0x442088).
    var exteriorIntro: [Int] {
        [[21007, 21008, 21009, 21010], [21000, 21001, 21002, 21003],
         [21130, 21131, 21132, 21133], [21106, 21107, 21108, 21109]][rawValue]
    }
    /// Bonus area behind the exterior's signpost.
    var bonusBackground: Int { [2100, 2900, 2300, 2500][rawValue] }
    var bonusMusic: Int { [32024, 32040, 32041, 32018][rawValue] }

    /// The activity's game scene (entered through the exterior's door).
    func makeGameScene() -> Scene {
        switch self {
        case .countingClub: return CountingClubScene()
        case .abcDiner: return ABCDinerScene()
        case .shapeShack: return ShapeShackScene()
        case .patternParade: return PatternParadeScene()
        }
    }
}

/// Main menu carousel (enter FUN_00419983, layout COMB 8810, background 2000).
final class MainMenuScene: LayoutScene {
    /// Lip-synced greetings, cycled on each visit (pointer table at 0x441b20).
    static let greetings: [[Int]] = [
        [21052, 21055], [21060, 21062], [21074], [21058, 21059], [21065, 21068],
        [21101], [21100], [21099], [21090, 21091, 21092], [21095],
    ]
    private var greet: Bool

    init(greet: Bool = true) {
        self.greet = greet
        super.init(comb: 8810)
        bodyId = 208
    }

    override func configure(_ game: Game) {
        game.stopMusic()
        // Keys: four per activity corner in layout order, one per level.
        var keyIndex = 0
        var horseIndex = 0
        for item in items {
            if item.id == 2002, let a = item.actor {
                let activity = keyIndex / 4, level = keyIndex % 4
                a.step = game.player.keys[activity][level] ? 1 : 2
                keyIndex += 1
            }
            // Carousel horses: one per activity, pose chosen by keys earned
            // (FUN_00419555: step = keys*4 + table 0x441a86[i] + 2).
            if item.id == 510, let a = item.actor {
                let order = [3, 0, 1, 2]
                let keys = game.player.keys[horseIndex].filter { $0 }.count
                let step = keys * 4 + order[horseIndex] + 2
                if a.aseq.step(step) != nil { a.step = step }
                horseIndex += 1
            }
        }
        if greet {
            let g = Self.greetings[game.menuVisits % Self.greetings.count]
            game.menuVisits += 1
            runScript(g)
        }
    }

    override func click(_ game: Game, x: Int, y: Int) {
        guard let item = hitTest(x, y) else { return }
        switch item.id {
        case -10, -12, -14, -16:
            goToExterior(game, Activity(rawValue: (-item.id - 10) / 2)!)
        case 2002:
            break
        case 530: // keyhole
            if game.player.totalKeys == 16 {
                game.say(3775)
            } else {
                game.say(3775)
            }
            activate(item)
        case 510: // carousel
            stopScript(game)
            game.say(game.random(2) == 0 ? 2072 : 2066)
        case 2090: // quit sign
            stopScript(game)
            game.requestQuit()
        case 205, 208:
            stopScript(game)
            runScript(Self.greetings[game.random(Self.greetings.count)])
        default:
            if item.actor != nil {
                stopScript(game)
                activate(item)
            }
        }
    }

    override func key(_ game: Game, _ key: Key) {
        switch key {
        case .left: goToExterior(game, .countingClub)
        case .up: goToExterior(game, .abcDiner)
        case .right: goToExterior(game, .shapeShack)
        case .down: goToExterior(game, .patternParade)
        case .escape: game.requestQuit()
        default: break
        }
    }

    private func goToExterior(_ game: Game, _ a: Activity) {
        game.activity = a.rawValue
        game.change(to: ExteriorScene(a), sound: a.toExteriorSpeech)
    }
}

/// Activity exterior (shared enter FUN_0041f462, mouse FUN_0041ec86 / FUN_0041ee75).
final class ExteriorScene: LayoutScene {
    let activity: Activity
    /// Item whose exit animation must finish before leaving (DAT_00447d88).
    private var leaving: (item: Item, target: () -> Scene)?

    init(_ activity: Activity) {
        self.activity = activity
        super.init(comb: activity.exteriorComb)
        staticIds = [activity.exteriorBackground + 1, activity.exteriorBackground + 2]
    }

    override func configure(_ game: Game) {
        game.activity = activity.rawValue
        if !game.introducedExteriors.contains(activity.rawValue) {
            game.introducedExteriors.insert(activity.rawValue)
            runScript(activity.exteriorIntro)
        }
    }

    override func click(_ game: Game, x: Int, y: Int) {
        guard leaving == nil, let item = hitTest(x, y) else { return }
        let id = item.id
        if id == 0 || id == activity.exteriorBackground + 1 || [2402, 2851, 3502, 3506].contains(id) {
            enterActivity(game)
            return
        }
        if id < 0 {
            stopScript(game)
            trigger(-id)
            return
        }
        switch id {
        case 610...613:
            leave(game, item, sound: 2201) {
                ExteriorScene(Activity(rawValue: (self.activity.rawValue + 3) % 4)!)
            }
        case 620...623:
            leave(game, item, sound: 2202) {
                ExteriorScene(Activity(rawValue: (self.activity.rawValue + 1) % 4)!)
            }
        case 900:
            leave(game, item, sound: 2200) { MainMenuScene() }
        case 2095...2098:
            stopScript(game)
            game.change(to: BonusScene(activity))
        case 205, 206:
            stopScript(game)
            runScript(activity.exteriorIntro)
        default:
            stopScript(game)
            activate(item)
        }
    }

    override func key(_ game: Game, _ key: Key) {
        switch key {
        case .escape: game.change(to: MainMenuScene(), sound: 2200)
        case .enter: enterActivity(game)
        default: break
        }
    }

    private func leave(_ game: Game, _ item: Item, sound: Int, _ target: @escaping () -> Scene) {
        stopScript(game)
        item.state = .playing
        game.say(sound)
        leaving = (item, target)
    }

    override func afterTick(_ game: Game) {
        if let l = leaving, l.item.state == .idle {
            leaving = nil
            game.change(to: l.target())
        }
    }

    private func enterActivity(_ game: Game) {
        stopScript(game)
        game.change(to: activity.makeGameScene(), sound: activity.enterSpeech)
    }
}
