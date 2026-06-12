import Foundation
import Logging
import SwiftNotCurses

@MainActor
public class UI {

    internal static var notcurses: NotCurses?

    private let inputQueue: InputQueue

    public static var running: Bool = true

    private let stdPlane: Plane

    private var pageManager: UIPageManager

    internal static var mode: UIMode = .normal

    private let frameDelay: UInt64

    public init() async {

        let flags: [UIOptionFlag] = [
            .inhibitSetLocale,
            .noFontChanges,
            .noWinchSighandler,
            .noQuitSighandlers,
            .suppressBanners,
        ]

        let config = Config.shared

        var opts = UIOptions(
            logLevel: config.logging.ncLogLevel,
            config: config.ui,
            flags: flags
        )

        self.frameDelay = config.ui.frameDelay

        self.inputQueue = InputQueue.shared
        inputQueue.mappings = config.mappings

        logger?.info("Initializing UI with options: \(opts)")
        guard let notcurses = NotCurses(opts: &opts) else {
            fatalError("Failed to initialize notcurses UI.")
        }
        UI.notcurses = notcurses
        Self.resetGhosttyKeyboardProtocol()
        logger?.debug("Notcurses initialized.")

        guard let stdPlane = Plane(in: notcurses) else {
            fatalError("Failed to initialize notcurses std plane")
        }
        self.stdPlane = stdPlane

        guard
            let pageManager = await UIPageManager(
                uiConfig: config.ui,
                stdPlane: stdPlane
            )
        else {
            fatalError("Failed to initiate PageManager.")
        }
        self.pageManager = pageManager
        await handleResize()

        setupSigwinchHandler {
            if !config.settings.disableResize {
                await self.handleResize()
            }
        }
        setupSigintHandler {}

        logger?.info("UI initialized successfully.")
    }

    public func start() async {

        await pageManager.resizePages(stdPlane.width, stdPlane.height)

        await inputQueue.start()

        await appLoop()
    }

    private func appLoop() async {

        while UI.running {

            await handleInput()

            await pageManager.renderPages()

            UI.notcurses?.render()

            try! await Task.sleep(nanoseconds: frameDelay)
        }

        await stop()
    }

    func handleResize() async {
        logger?.trace("Resize occured: Refreshing...")
        UI.notcurses?.refresh()
        let newWidth = stdPlane.width
        let newHeight = stdPlane.height
        logger?.trace(
            "Resize occured: New width \(newWidth), new height: \(newHeight)"
        )

        await pageManager.resizePages(newWidth, newHeight)
        await pageManager.windowTooSmallPage.render()

        logger?.debug("Resize handled.")
    }

    func handleInput() async {
        guard let notcurses = UI.notcurses else {
            return
        }
        guard let input = Input(notcurses: notcurses) else {
            return
        }
        // Only happens in iTerm2
        // Every other terminal just sends "unknown" instead
        // So this is actually how it is supposed to work
        guard input.eventType != .release else {
            return
        }
        // Drain all available input in one pass so that escape sequences
        // (e.g. Ghostty bracketed-paste \e[200~...\e[201~ or IME sequences)
        // are normalized before InputQueue processes the leading ESC.
        var inputs = [input]
        logger?.trace("New input: \(input)")
        while let extra = Input(notcurses: notcurses) {
            guard extra.eventType != .release else { continue }
            logger?.trace("New input: \(extra)")
            inputs.append(extra)
        }
        for input in normalizeInputs(inputs) {
            inputQueue.add(input)
        }
    }

    private func normalizeInputs(_ inputs: [Input]) -> [Input] {
        var normalized: [Input] = []
        var index = inputs.startIndex

        while index < inputs.endIndex {
            if let result = decodeBareCSIUInput(in: inputs, startingAt: index) {
                normalized.append(result.input)
                index = result.nextIndex
                continue
            }

            if let result = decodeCSIUInput(in: inputs, startingAt: index) {
                normalized.append(result.input)
                index = result.nextIndex
                continue
            }

            normalized.append(inputs[index])
            index = inputs.index(after: index)
        }

        return normalized
    }

    private func decodeBareCSIUInput(
        in inputs: [Input],
        startingAt startIndex: Array<Input>.Index
    ) -> (input: Input, nextIndex: Array<Input>.Index)? {
        let input = inputs[startIndex]

        if input.id > 0x7F, input.utf8 == "u",
            let decoded = inputForBareUnicodeScalar(input.id)
        {
            return (decoded, inputs.index(after: startIndex))
        }

        if input.modifiers.isEmpty, input.utf8.hasSuffix("u") {
            let codepoint = String(input.utf8.dropLast())
            if let decoded = inputForBareUnicodeScalar(codepoint) {
                return (decoded, inputs.index(after: startIndex))
            }
        }

        var index = startIndex
        var codepoint = ""

        while index < inputs.endIndex {
            guard let token = token(for: inputs[index]) else {
                return nil
            }

            if token == "u" {
                guard let decoded = inputForBareUnicodeScalar(codepoint) else {
                    return nil
                }
                return (decoded, inputs.index(after: index))
            }

            guard token.count == 1, token.allSatisfy(\.isNumber) else {
                return nil
            }
            codepoint.append(token)
            index = inputs.index(after: index)
        }

        return nil
    }

    private func decodeCSIUInput(
        in inputs: [Input],
        startingAt startIndex: Array<Input>.Index
    ) -> (input: Input, nextIndex: Array<Input>.Index)? {
        guard token(for: inputs[startIndex]) == "\u{1B}" else {
            return nil
        }

        var index = inputs.index(after: startIndex)
        guard index < inputs.endIndex, token(for: inputs[index]) == "[" else {
            return nil
        }

        index = inputs.index(after: index)
        var codepoint = ""

        while index < inputs.endIndex {
            guard let token = token(for: inputs[index]) else {
                return nil
            }

            if token == "u" {
                guard let decoded = inputForUnicodeScalar(codepoint) else {
                    return nil
                }
                return (decoded, inputs.index(after: index))
            }

            if token == ";" {
                guard !codepoint.isEmpty else {
                    return nil
                }
                return decodeCSIUInputWithModifiers(
                    codepoint: codepoint,
                    in: inputs,
                    startingAt: inputs.index(after: index)
                )
            }

            guard token.count == 1, token.allSatisfy(\.isNumber) else {
                return nil
            }
            codepoint.append(token)
            index = inputs.index(after: index)
        }

        return nil
    }

    private func decodeCSIUInputWithModifiers(
        codepoint: String,
        in inputs: [Input],
        startingAt startIndex: Array<Input>.Index
    ) -> (input: Input, nextIndex: Array<Input>.Index)? {
        var index = startIndex

        while index < inputs.endIndex {
            guard let token = token(for: inputs[index]) else {
                return nil
            }

            if token == "u" {
                guard let decoded = inputForUnicodeScalar(codepoint) else {
                    return nil
                }
                return (decoded, inputs.index(after: index))
            }

            guard token.count == 1, token.allSatisfy(\.isNumber) else {
                return nil
            }
            index = inputs.index(after: index)
        }

        return nil
    }

    private func inputForBareUnicodeScalar(_ codepoint: String) -> Input? {
        guard let scalarValue = UInt32(codepoint) else {
            return nil
        }
        return inputForBareUnicodeScalar(scalarValue)
    }

    private func inputForBareUnicodeScalar(_ scalarValue: UInt32) -> Input? {
        guard scalarValue >= 0x1000 else {
            return nil
        }
        return inputForUnicodeScalar(scalarValue)
    }

    private func inputForUnicodeScalar(_ codepoint: String) -> Input? {
        guard let scalarValue = UInt32(codepoint) else {
            return nil
        }
        return inputForUnicodeScalar(scalarValue)
    }

    private func inputForUnicodeScalar(_ scalarValue: UInt32) -> Input? {
        guard
            scalarValue > 0x7F,
            let scalar = UnicodeScalar(scalarValue)
        else {
            return nil
        }
        return Input(utf8: String(Character(scalar)))
    }

    private func token(for input: Input) -> String? {
        if input.id == 27 || input.utf8 == "\u{1B}" {
            return "\u{1B}"
        }
        guard input.modifiers.isEmpty, input.utf8.count == 1 else {
            return nil
        }
        return input.utf8
    }

    public func stop() async {
        await pageManager.onQuit()
        logger?.info("Stopping Yatoro...")

        // Fix for artwork not getting destroyed in iTerm2
        UI.notcurses?.render()

        // Workaround for iTerm2 not recovering state after quitting Yatoro
        if let termProg = ProcessInfo.processInfo.environment["TERM_PROGRAM"],
            termProg == "iTerm.app"
        {
            if !Config.shared.settings.disableITermWorkaround {
                let sequence = "\u{1B}[=0u"
                FileHandle.standardOutput.write(sequence.data(using: .utf8)!)
            }
        }
        Self.resetGhosttyKeyboardProtocol()

        UI.notcurses?.stop()
        logger?.debug("Notcurses stopped.")
        logger?.info("Yatoro stopped.\n")
        exit(EXIT_SUCCESS)
    }

    private static func resetGhosttyKeyboardProtocol() {
        guard
            ProcessInfo.processInfo.environment["TERM_PROGRAM"]?.lowercased() == "ghostty"
        else {
            return
        }

        let sequence = "\u{1B}[<u"
        FileHandle.standardOutput.write(sequence.data(using: .utf8)!)
    }

}

public enum UIMode {
    case normal
    case command
}
