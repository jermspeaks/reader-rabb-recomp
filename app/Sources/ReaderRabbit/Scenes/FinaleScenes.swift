import Foundation

/// The finale unlocked by all 16 keys (Ending_Enter FUN_004333d8):
/// slides 30410 → 30420 → 30430 with step-cued sounds (table 0x445b18), then
/// the credits 31440, drawn one picture per tick from ASEQ 31441–31850 over
/// MUSIC 30999, and back to the main menu (FUN_00433424 → FUN_00419983).
/// A click or Enter skips the current slide (or the credits).
final class EndingScene: SlideshowScene {
    static let credits = 31440

    init() { super.init(id: 30410, slides: [30420, 30430, EndingScene.credits], cueTable: 0x445b18) }

    /// 30430 and the credits clear to black and load their own palette;
    /// 30420 keeps 30410's.
    override func willShow(_ game: Game, slide: Int) {
        let ownPalette = slide == 30430 || slide == Self.credits
        show(game, slide: slide, palette: ownPalette ? slide : paletteId,
             animations: slide == Self.credits ? 0 : 1)
    }

    override func slideTick(_ game: Game) {
        guard currentSlide == Self.credits else { super.slideTick(game); return }
        counter += 1
        if counter == 2 { game.playMusic(30999, loop: false) }
        if counter < 0x19B {
            stampFirstFrame(game, Self.credits + counter)
        } else {
            next(game, skip: false)
        }
    }

    override func click(_ game: Game, x: Int, y: Int) {
        skipSlide(game)
    }

    override func key(_ game: Game, _ key: Key) {
        if key == .enter || key == .char("\u{3}") { skipSlide(game); return }
        super.key(game, key)
    }

    override func next(_ game: Game, skip: Bool) {
        if skip { game.stopSpeech() }
        game.change(to: MainMenuScene())
    }
}

extension MainMenuScene {
    /// All four activities have all four keys (DAT_00447370 == 16 and FUN_0041818d() == 4).
    static func finaleUnlocked(_ game: Game) -> Bool {
        game.player.totalKeys == 16
    }

    /// Keyhole 530 with every key (FUN_00419223 case 0x212): mark the ending as
    /// seen (record +0x88 = 17) and play it.
    func startFinale(_ game: Game) {
        stopScript(game)
        game.player.endingSeen = true
        game.savePlayer()
        game.change(to: EndingScene())
    }
}
