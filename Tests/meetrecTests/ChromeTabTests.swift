import AppKit
import Foundation
import Testing

@testable import meetrec

@Test func printChromeTabURLsWithAppleScript() {
    let logger = TestLogging.logger
    let source = """
    tell application "Google Chrome"
        set results to {}
        repeat with w in windows
            repeat with t in tabs of w
                set end of results to (URL of t)
            end repeat
        end repeat
        return results
    end tell
    """

    logger.info("Creating the Google Chrome AppleScript.")
    guard let script = NSAppleScript(source: source) else {
        logger.error("Could not create the Google Chrome AppleScript.")
        return
    }

    logger.info("Executing NSAppleScript.executeAndReturnError.")
    var error: NSDictionary?
    let result = script.executeAndReturnError(&error)
    if let error {
        logger.error("Google Chrome AppleScript failed: \(String(describing: error))")
        return
    }

    let itemCount = result.numberOfItems
    logger.info("Google Chrome AppleScript returned \(itemCount) tab URL(s).")
    guard itemCount > 0 else { return }

    for index in 1...itemCount {
        if let url = result.atIndex(index)?.stringValue {
            logger.info("Tab URL [\(index)]: \(url)")
        } else {
            logger.warning("Google Chrome returned an item without a string URL at index \(index).")
        }
    }
}
