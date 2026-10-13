import Foundation

/// ABC Diner (RRPW32.EXE enter FUN_00430888, tick FUN_0042db8e, mouse
/// FUN_0042fcd4, key FUN_00430544; docs/game-logic.md §4.4–5).
///
/// The chef names a food (level 0) or a letter (levels 1–3). The child opens
/// one of six lettered cupboards and serves the food in the bowl. An order is
/// three items; a perfect order advances the progress meter, and eight
/// perfect orders earn the level's key.
final class ABCDinerScene: Scene {
    // MARK: Data read from the user's RRPW32.EXE

    /// Food names indexed by letter + 27 × list (table 0x444e14, '@' = 1, A = 2 … Z = 27).
    private var foodNames: [String?] = []
    /// 120 order strings (table 0x444ef0): 20 sets × 3 variants, then the same for levels 2–3.
    private var orders: [String] = []

    // MARK: Layout (RRPW32.EXE FUN_0042d057, tables 0x444da0 / 0x444dce)

    private static let cupboards: [(x: Int, y: Int, aseq: Int)] = [
        (165, 48, 8001), (277, 48, 8001), (277, 131, 8001),
        (392, 52, 8002), (392, 134, 8002), (392, 216, 8002),
    ]
    private static let ticketRows = [346, 373, 400]
    private static let tryAgain = [16104, 16105, 16107, 16112, 16113]
    private static let praise = [16106, 16108, 16109, 16110, 16115, 16116, 16117, 16118]
    private static let exitSpeech = [21116, 21121, 21122, 21124, 21125, 21046, 21066]
    /// Non-food gag items (table 0x44547c): never the answer.
    private static let gagCodes: Set<Int> = [2, 3, 5, 13, 21, 33, 45]

    private var doors: [Actor] = []
    private var cards: [Actor] = []
    private var foods: [Actor] = []
    private var chef: Actor?
    private var waiter: Actor?
    private var bowl: Actor?
    private var meter: Actor?
    private var exitSign: Actor?
    private var tickets: [Actor] = []
    private var smallFont: BitmapFont?
    private var ticketFont: BitmapFont?

    // MARK: Game state

    private var level = 0
    private var lowercase = false
    private var setOrder: [Int] = []
    private var currentSet = 0
    private var variantOrder: [Int] = [0, 1, 2]
    /// Shelf letters (letter index) and lists for positions 0–5.
    private var shelf: [(letter: Int, list: Int)] = []
    private var wanted: [Int] = []          // item codes for the three items
    private var served: [Int?] = [nil, nil, nil]
    private var missed: [Bool] = [false, false, false]
    private var item = 0
    private var misses = 0
    private var customer = 0
    private var selected: Int?
    private var servedFood: FoodFlight?
    private var foodReturning = false
    private var chefGesture: Actor?
    private var customerReaction: Actor?
    private var showSequence: [Int] = []
    private var showActor: Actor?
    private var showActorTicks = 0

    private struct FoodFlight {
        var code: Int
        var fromX: Int
        var fromY: Int
        var toX: Int
        var toY: Int
        var progress = 0
    }

    private enum Phase {
        case intro, arrive, prompt, waitInput, opening, serving, feedback, recap, reaction, bonus, reward, rewardExit, leaving
    }
    private var phase = Phase.intro
    private var script: [Int] = []
    private var scriptDelay = 0
    private var phaseTicks = 0
    private var idleTicks = 0
    private var firstVisit = true

    init() {}

    // MARK: Enter / exit

    func enter(_ game: Game) {
        level = min(3, game.player.level[Activity.abcDiner.rawValue])
        lowercase = game.player.lowercase
        if let exe = game.exe {
            foodNames = exe.stringTable(at: 0x444e14, count: 55)
            orders = exe.stringTable(at: 0x444ef0, count: 120).map { $0 ?? "" }
        }
        game.setBackground(32687)
        smallFont = game.res.font(1014)
        ticketFont = game.res.font(1018)
        let r = game.res
        for c in Self.cupboards {
            if let a = r.aseq(c.aseq) { doors.append(Actor(a, x: c.x, y: c.y, step: 1)) }
        }
        if let a = r.aseq(8100) { chef = Actor(a, x: 87, y: 151, step: 1) }
        if let a = r.aseq(8200) { waiter = Actor(a, x: 481, y: 160, step: 1) }
        if let a = r.aseq(8321) { bowl = Actor(a, x: 188, y: 257, step: 1) }
        if let a = r.aseq(502) { meter = Actor(a, x: 39, y: 401, step: 1) }
        if let a = r.aseq(212) { exitSign = Actor(a, x: 480, y: 406, step: 1) }
        if let a = r.aseq(8014) { tickets = Self.ticketRows.map { Actor(a, x: 214, y: $0, step: 1) } }
        setOrder = Array(0..<20).shuffled()
        if game.player.progress[Activity.abcDiner.rawValue] > 7 {
            game.player.completeLevel(Activity.abcDiner.rawValue)
            level = min(3, game.player.level[Activity.abcDiner.rawValue])
        }
        firstVisit = !game.player.usedContent[Activity.abcDiner.rawValue].contains(-1)
        newOrder(game)
        // Intro scripts (pointer table 0x445128): long first visit, short per level.
        let intros: [[Int]] = [
            [16122, 16121, -4, 16137, 16138, -2, 16152, 16153, 16120, 16149, -2],
            [16125, 16127, -4], [16123, 16124, -4, 16127, -4], [16125, 16154, 16129, -4],
            [16125, 16154, 16129, -4],
        ]
        runScript(firstVisit ? intros[0] : intros[level + 1])
        if firstVisit { game.player.usedContent[Activity.abcDiner.rawValue].append(-1) }
        phase = .intro
    }

    func exit(_ game: Game) {
        game.stopMusic()
        game.savePlayer()
    }

    // MARK: Orders (FUN_0042c927 / FUN_0042c73b)

    private func newOrder(_ game: Game) {
        let used = Set(game.player.usedContent[Activity.abcDiner.rawValue])
        currentSet = setOrder.first { !used.contains($0) } ?? setOrder[0]
        setOrder.removeAll { $0 == currentSet }
        setOrder.append(currentSet)
        variantOrder = [0, 1, 2].shuffled()
        var c = game.random(22)
        while c == customer { c = game.random(22) }
        customer = c
        wanted = []
        served = [nil, nil, nil]
        missed = [false, false, false]
        customerReaction = nil
        item = 0
        misses = 0
        buildShelf(game)
    }

    /// Fill the six cupboards for the current item and record the wanted code.
    private func buildShelf(_ game: Game) {
        let row = currentSet * 3 + variantOrder[item] + (level > 1 ? 60 : 0)
        let chars = Array((orders.indices.contains(row) ? orders[row] : "bABCMSW").utf8)
        guard chars.count >= 7 else { return }
        let target = Int(chars[0]) - 0x5F
        var list = game.random(2)
        var targetList = 0
        shelf = []
        for k in 1...6 {
            let letter = Int(chars[k]) - 0x3F
            var l = list
            if l != 0 && name(letter, 1) == nil { l = 0 }
            if l == 0 && name(letter, 0) == nil { l = 1 }
            shelf.append((letter, l))
            list = 1 - l
            if letter == target { targetList = l }
        }
        // Shuffle positions, then pin vowels where their gag animations expect them.
        for k in 0..<6 { shelf.swapAt(k, game.random(6)) }
        let vowels: Set<Int> = [2, 6, 10, 16, 22]
        if vowels.contains(shelf[1].letter) { shelf.swapAt(1, 3) }
        if vowels.contains(shelf[2].letter) { shelf.swapAt(2, 0) }
        if vowels.contains(shelf[4].letter) { shelf.swapAt(4, 5) }
        let code = target * 2 + targetList
        if wanted.count > item { wanted[item] = code } else { wanted.append(code) }
        placeShelf(game)
    }

    private func placeShelf(_ game: Game) {
        let r = game.res
        guard let cardA = r.aseq(lowercase ? 8012 : 8010), let foodA = r.aseq(8023) else { return }
        cards = []
        foods = []
        for (k, door) in doors.enumerated() {
            door.step = 1
            let rect = door.rect
            let card = Actor(cardA, step: shelf[k].letter)
            if let s = card.sprite {
                card.x = rect.x + (rect.w - s.width) / 2
                card.y = rect.y + (rect.h - s.height) / 2
            }
            cards.append(card)
            let food = Actor(foodA, step: shelf[k].letter + shelf[k].list * 27)
            if let s = food.sprite {
                food.x = rect.x + (rect.w - s.width) / 2
                food.y = rect.y + rect.h - s.height + (k > 2 ? 2 : 0) - 8
            }
            foods.append(food)
        }
        selected = nil
    }

    private func name(_ letter: Int, _ list: Int) -> String? {
        let i = letter + 27 * list
        return foodNames.indices.contains(i) ? foodNames[i] : nil
    }

    private func codeName(_ code: Int) -> String {
        (name(code / 2, code & 1) ?? "").trimmingCharacters(in: .whitespaces)
    }

    // MARK: Speech

    private func runScript(_ ids: [Int]) {
        script = ids
        scriptDelay = 0
    }

    private var scriptDone: Bool { script.isEmpty && scriptDelay == 0 }

    private func stepScript(_ game: Game) {
        if let gesture = chefGesture {
            if gesture.advance() == .ended { chefGesture = nil }
            return
        }
        guard game.mouth == nil, !game.speechPlaying else { return }
        if scriptDelay > 0 { scriptDelay -= 1; return }
        guard !script.isEmpty else { return }
        let v = script.removeFirst()
        if v < 0 {
            scriptDelay = -v
        } else if (1...4).contains(v) {
            if let a = game.res.aseq(8099 + v), let chef {
                chefGesture = Actor(a, x: chef.x, y: chef.y, step: a.steps.firstIndex(where: { $0.frame >= 0 }) ?? 0)
            }
        } else {
            game.sayWithLips(v)
        }
    }

    /// Prompt for the current item (pointer table 0x44517c, patched in state 9).
    private func promptScript() -> [Int] {
        let code = wanted[item]
        switch level {
        case 0: return [16100, 17496 + code]
        case 2: return [16102, 12598 + code / 2]
        default: return [16101, 12598 + code / 2]
        }
    }

    // MARK: Tick

    func tick(_ game: Game) {
        stepScript(game)
        if let reaction = customerReaction, reaction.advance() != .moved { customerReaction = nil }
        animateSpeakers(game)
        animateDoors()
        phaseTicks += 1
        switch phase {
        case .intro:
            if scriptDone { phase = .arrive; phaseTicks = 0; runScript([11000 + 3 * customer]) }
        case .arrive:
            if scriptDone { startPrompt() }
        case .prompt:
            if scriptDone { phase = .waitInput; idleTicks = 0 }
        case .waitInput, .opening:
            idleTicks += 1
            // Idle hint after ~5 s: repeat the request.
            if idleTicks > 43, scriptDone, !game.speechPlaying {
                idleTicks = 0
                runScript(promptScript())
            }
        case .serving:
            if var flight = servedFood {
                flight.progress = min(4, phaseTicks)
                servedFood = flight
            }
            if phaseTicks >= 4 { checkServed(game) }
        case .feedback:
            if foodReturning, var flight = servedFood {
                flight.progress = max(0, 4 - phaseTicks)
                servedFood = flight
            }
            if scriptDone, phaseTicks > 3 { nextItem(game) }
        case .recap:
            if scriptDone { finishOrder(game) }
        case .reaction:
            if scriptDone, phaseTicks > 2 { afterReaction(game) }
        case .bonus:
            if tickShow(game) {
                newOrder(game)
                phase = .intro
                phaseTicks = 0
            }
        case .reward:
            if tickShow(game) {
                game.player.completeLevel(Activity.abcDiner.rawValue)
                game.savePlayer()
                runScript([-4, Self.praise[game.random(Self.praise.count)], -2])
                phase = .rewardExit
                phaseTicks = 0
            }
        case .rewardExit:
            if scriptDone, phaseTicks > 6 {
                phase = .leaving
                game.change(to: MainMenuScene(greet: false),
                            sound: Self.exitSpeech[game.random(Self.exitSpeech.count)])
            }
        case .leaving:
            break
        }
    }

    private func startPrompt() {
        phase = .prompt
        phaseTicks = 0
        runScript(promptScript())
    }

    private func animateSpeakers(_ game: Game) {
        let m = game.mouth, who = game.mouthActor
        if let chef {
            if let gesture = chefGesture {
                chef.set(gesture.aseq, step: gesture.step)
            } else if who == 8100, let m {
                chef.set(game.res.aseq(8100) ?? chef.aseq, step: m + 1)
            } else {
                chef.set(game.res.aseq(8100) ?? chef.aseq, step: 1)
            }
        }
        if let waiter {
            if who == 8210, let m, let talk = game.res.aseq(8210) {
                waiter.set(talk, step: m + 1)
            } else if let idle = game.res.aseq(8200) {
                waiter.set(idle, step: 1)
            }
        }
    }

    /// Selected cupboard opens to step 6 (widest); others close back to step 1.
    private func animateDoors() {
        for (k, door) in doors.enumerated() {
            if k == selected {
                if door.step < 6 { door.step += 1 }
            } else if door.step > 1 {
                door.step = door.step >= 6 ? 7 + (door.step - 6) : door.step + 1
                if door.step >= 11 { door.step = 1 }
            }
        }
    }

    // MARK: Input (FUN_0042fcd4)

    func click(_ game: Game, x: Int, y: Int) {
        if exitSign?.rect.contains(x, y) == true { leave(game); return }
        guard phase == .waitInput || phase == .opening || phase == .prompt else {
            if phase == .intro, chef?.rect.contains(x, y) == true { script = []; game.stopSpeech() }
            return
        }
        for k in (0..<6).reversed() where doors[k].rect.contains(x, y) {
            select(game, k)
            return
        }
        if let bowl, bowl.rect.contains(x, y), selected != nil {
            serve(game)
            return
        }
        if chef?.rect.contains(x, y) == true || waiter?.rect.contains(x, y) == true {
            game.stopSpeech()
            runScript(promptScript())
            return
        }
        for (row, t) in tickets.enumerated() where row <= item && t.rect.contains(x, y) {
            game.say(12598 + wanted[row] / 2)
            return
        }
    }

    func key(_ game: Game, _ key: Key) {
        switch key {
        case .escape: leave(game)
        case .space:
            guard phase == .waitInput || phase == .opening else { return }
            select(game, ((selected ?? -1) + 1) % 6)
        case .enter:
            if selected != nil, phase == .waitInput || phase == .opening { serve(game) }
        case .char("1"):
            game.stopSpeech()
            runScript(promptScript())
        default: break
        }
    }

    private func select(_ game: Game, _ k: Int) {
        script = []
        game.stopSpeech()
        selected = k
        phase = .opening
        idleTicks = 0
        let code = shelf[k].letter * 2 + shelf[k].list
        if Self.gagCodes.contains(code) {
            game.say(code <= 3 ? 8130 + game.random(5) : 8135 + game.random(5))
        } else if level == 0 {
            game.sayWithLips((code & ~1) + 6796)
        } else if level >= 2 {
            game.say(11998 + code)
        }
    }

    private func serve(_ game: Game) {
        guard let k = selected else { return }
        script = []
        game.stopSpeech()
        let code = shelf[k].letter * 2 + shelf[k].list
        if let bowlRect = bowl?.rect, let s = foods[k].sprite {
            let source = foods[k].rect
            servedFood = FoodFlight(code: code, fromX: source.x, fromY: source.y,
                                    toX: bowlRect.midX - s.width / 2, toY: bowlRect.y - s.height + 14)
        }
        foodReturning = false
        served[item] = code
        foods[k].hidden = true
        selected = nil
        phase = .serving
        phaseTicks = 0
        bowl?.step = 2
    }

    /// FUN_0042d7db: exact code match, or the same letter at levels 2–3.
    private func checkServed(_ game: Game) {
        bowl?.step = 1
        guard let code = served[item] else { return }
        let want = wanted[item]
        let correct = code == want || (level > 1 && code & ~1 == want & ~1)
        if correct {
            game.say(8110)
            runScript([2, -3])
        } else {
            missed[item] = true
            misses += 1
            foodReturning = true
            game.say(8116)
            runScript([3, -3, Self.tryAgain[game.random(Self.tryAgain.count)]])
        }
        phase = .feedback
        phaseTicks = 0
    }

    private func nextItem(_ game: Game) {
        servedFood = nil
        foodReturning = false
        item += 1
        if item < 3 {
            buildShelf(game)
            startPrompt()
        } else {
            // Recap (0x44518c): "You served…" then each food, then the verdict.
            var s: [Int] = [16131 + game.random(3), -2]
            for (i, code) in served.enumerated() where !missed[i] {
                if let code { s += [17110 + code, -2] }
            }
            s.append(misses == 0 ? 17113 : 17111)
            runScript(s)
            phase = .recap
            phaseTicks = 0
        }
    }

    private func finishOrder(_ game: Game) {
        let reaction = misses == 0 ? 8501 + 2 * game.random(3) : 8502 + 2 * game.random(4)
        customerReaction = game.res.aseq(reaction).map { Actor($0, x: 481, y: 160, step: $0.steps.firstIndex(where: { $0.frame >= 0 }) ?? 0) }
        runScript([(misses == 0 ? 11001 : 11002) + 3 * customer])
        phase = .reaction
        phaseTicks = 0
    }

    /// Progress (FUN_0042c602 / FUN_0042c4e9): only perfect orders count.
    private func afterReaction(_ game: Game) {
        let act = Activity.abcDiner.rawValue
        if misses == 0 {
            game.player.usedContent[act].append(currentSet)
            game.player.progress[act] += 1
            let p = game.player.progress[act]
            game.say(25000 + (p + 1) / 2)
            if p >= 8 {
                startShow(game, [8520, 8521, 8531 + level])
                phase = .reward
                phaseTicks = 0
                return
            }
            game.savePlayer()
            if p == 4 {
                let finale = level == 0 ? 8400 : 8601 + game.random(4)
                startShow(game, [8230, 8231, 8232, 8606,
                                 game.random(2) == 0 ? 8600 : 8605, finale])
                phase = .bonus
                phaseTicks = 0
                return
            }
            runScript([-4, Self.praise[game.random(Self.praise.count)]])
        }
        newOrder(game)
        phase = .intro
        phaseTicks = 0
    }

    /// Show resources and order are observed in the original; centering them as
    /// a single sequence is an approximation pending a local visual comparison.
    private func startShow(_ game: Game, _ ids: [Int]) {
        showSequence = ids
        showActor = nil
        showActorTicks = 0
        customerReaction = nil
    }

    private func tickShow(_ game: Game) -> Bool {
        while showActor == nil {
            guard !showSequence.isEmpty else { return true }
            let id = showSequence.removeFirst()
            guard let a = game.res.aseq(id) else { continue }
            showActor = Actor(a, step: a.steps.firstIndex(where: { $0.frame >= 0 }) ?? 0)
            showActorTicks = 0
            centerShowActor()
        }
        guard let showActor else { return showSequence.isEmpty }
        showActorTicks += 1
        if showActor.advance() == .ended || showActorTicks >= 90 {
            self.showActor = nil
        } else {
            centerShowActor()
        }
        return self.showActor == nil && showSequence.isEmpty
    }

    private func centerShowActor() {
        guard let showActor else { return }
        let r = showActor.rect
        showActor.x += 320 - r.midX
        showActor.y += 240 - r.midY
    }

    private func leave(_ game: Game) {
        phase = .leaving
        script = []
        game.change(to: ExteriorScene(.abcDiner))
        game.playMusic(32027 + game.random(6), loop: false)
    }

    // MARK: Development checks

    /// Centre of the cupboard holding the wanted item (headless `solve` command).
    func debugAnswerPoint(correct: Bool) -> (Int, Int)? {
        guard phase == .waitInput || phase == .opening || phase == .prompt, item < wanted.count else { return nil }
        let want = wanted[item]
        guard let k = shelf.indices.first(where: {
            let c = shelf[$0].letter * 2 + shelf[$0].list
            return (c == want || (level > 1 && c & ~1 == want & ~1)) == correct
        }) else { return nil }
        let r = doors[k].rect
        return (r.midX, r.midY)
    }

    var debugBowlPoint: (Int, Int)? { bowl.map { ($0.rect.midX, $0.rect.midY) } }
}

extension ABCDinerScene: DebugDrivable {
    /// `solve` serves the right food for the current item; `miss` serves a wrong one.
    func debugCommand(_ game: Game, _ args: [String]) -> Bool {
        guard args.first == "solve" || args.first == "miss" else { return false }
        for _ in 0..<400 {
            if let p = debugAnswerPoint(correct: args[0] == "solve") {
                game.mouseDown(x: p.0, y: p.1)
                for _ in 0..<7 { game.tick() }
                if let b = debugBowlPoint { game.mouseDown(x: b.0, y: b.1) }
                game.tick()
                return true
            }
            game.tick()
        }
        return true
    }
}

extension ABCDinerScene {
    // MARK: Drawing

    func draw(_ game: Game, _ fb: Framebuffer) {
        for (k, door) in doors.enumerated() {
            if door.step > 1 { foods[k].draw(fb) }
            door.draw(fb)
            if door.step == 1 { cards[k].draw(fb) }
        }
        chef?.draw(fb)
        waiter?.draw(fb)
        bowl?.draw(fb)
        if let f = servedFood, let a = game.res.aseq(8023), let s = Actor(a, step: f.code / 2 + (f.code & 1) * 27).sprite {
            let x = f.fromX + (f.toX - f.fromX) * f.progress / 4
            let y = f.fromY + (f.toY - f.fromY) * f.progress / 4
            fb.draw(s, x: x, y: y)
        }
        customerReaction?.draw(fb)
        showActor?.draw(fb)
        exitSign?.draw(fb)
        let act = Activity.abcDiner.rawValue
        let earned = game.player.keys[act][min(3, level)]
        meter?.step = (earned ? 8 : min(8, game.player.progress[act])) + 1
        meter?.draw(fb)
        if let smallFont {
            fb.drawText("Level \(level + 1)".macRoman, font: smallFont, x: 0x27, y: 0x1A1, color: 0x2A)
        }
        drawTicket(fb)
    }

    /// Order ticket (FUN_0042ca2b): letter in the box, food name once served.
    private func drawTicket(_ fb: Framebuffer) {
        guard let font = ticketFont else { return }
        for row in 0..<min(3, item + 1) where row < wanted.count {
            let t = tickets[row]
            t.draw(fb)
            let r = t.rect
            let code = wanted[row]
            var letter = String(UnicodeScalar(UInt8(0x3F + code / 2)))
            if lowercase { letter = letter.lowercased() }
            let color: UInt8 = missed[row] ? 2 : 0xDF
            let lb = letter.macRoman
            let baseline = r.y + r.h - 4 - (lowercase ? 2 : 0)
            fb.drawText(lb, font: font, x: r.x + (r.w - font.width(of: lb)) / 2, y: baseline, color: color)
            if row < item || (row == item && served[row] != nil && !missed[row]) {
                guard !missed[row] else { continue }
                var text = codeName(served[row] ?? code)
                if lowercase { text = text.lowercased() }
                fb.drawText(text.macRoman, font: font, x: r.x + r.w + 20, y: baseline, color: color)
            }
        }
    }
}
