import XCTest
@testable import HeadroomCore

private let epoch = Date(timeIntervalSince1970: 0)

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0, offsetHours: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: offsetHours * 3600)!
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
}

private func assertThrowsUsageError(
    _ body: @autoclosure () throws -> Any, file: StaticString = #filePath, line: UInt = #line
) -> UsageProviderError? {
    do {
        _ = try body()
        XCTFail("Expected a UsageProviderError", file: file, line: line)
    } catch let error as UsageProviderError {
        return error
    } catch {
        XCTFail("Unexpected error \(error)", file: file, line: line)
    }
    return nil
}

final class AntigravityUsageParserTests: XCTestCase {
    private let report = """
        {"conversation_id":"","status":"SUCCESS","response":"...","duration_seconds":0,"num_turns":0,
         "usage":{"input_tokens":0,"output_tokens":0,"total_tokens":0},
         "command":{"name":"usage","data":{"groups":[
           {"name":"Gemini Models","buckets":[
             {"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0.9985269904136658,"reset_time":"2026-11-07T15:15:30Z"},
             {"id":"gemini-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":1,"reset_time":"2026-11-02T17:27:31Z"}]},
           {"name":"Claude and GPT models","buckets":[
             {"id":"3p-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0.859639585018158,"reset_time":"2026-11-05T15:58:25Z"}]}]}}}
        """

    func testParsesGroupedBuckets() throws {
        let snapshot = try AntigravityUsageParser.parse(report, now: epoch)

        XCTAssertEqual(snapshot.windows.count, 3)
        let weekly = snapshot.windows[2]
        XCTAssertEqual(weekly.group, "Claude and GPT models")
        XCTAssertEqual(weekly.label, "Weekly")
        XCTAssertEqual(weekly.remainingPercent, 86, accuracy: 0.5)
        XCTAssertEqual(weekly.resetsAt, date(2026, 11, 5, 15, 58, 25))
        XCTAssertEqual(snapshot.windows[1].label, "5-hour")
        XCTAssertEqual(snapshot.mostConstrained, weekly)
    }

    func testFailedStatusIsReported() {
        let error = assertThrowsUsageError(
            try AntigravityUsageParser.parse(#"{"status":"ERROR","error":"sign in required"}"#, now: epoch))
        XCTAssertEqual(error?.kind, .signInRequired)
    }

    func testReportWithoutUsageCommandIsRejected() {
        XCTAssertNotNil(assertThrowsUsageError(
            try AntigravityUsageParser.parse(#"{"status":"SUCCESS","response":"Hello!"}"#, now: epoch)))
    }
}

final class CodexRateLimitParserTests: XCTestCase {
    func testParsesPrimaryAndSecondaryWindows() throws {
        let limits = try JSONValue.parse("""
            {"rateLimits":{"limitId":"codex","primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1793640172},
              "secondary":{"usedPercent":41,"windowDurationMins":10080,"resetsAt":1793778113},
              "credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"planType":"plus"},
             "rateLimitsByLimitId":{"codex":{"limitId":"codex"},
              "gpt-6":{"limitId":"gpt-6","limitName":"GPT-6","primary":{"usedPercent":50,"windowDurationMins":300}}}}
            """)
        let account = try JSONValue.parse(#"{"account":{"type":"chatgpt","email":"me@example.com","planType":"plus"}}"#)

        let snapshot = try CodexRateLimitParser.parse(limits, account: account, now: epoch)

        XCTAssertEqual(snapshot.windows.map(\.label), ["5-hour", "Weekly", "5-hour"])
        XCTAssertEqual(snapshot.windows[1].usedPercent, 41)
        XCTAssertEqual(snapshot.windows[1].resetsAt, Date(timeIntervalSince1970: 1793778113))
        XCTAssertEqual(snapshot.windows[2].group, "GPT-6")
        XCTAssertEqual(snapshot.plan, "Plus")
        XCTAssertEqual(snapshot.account, "me@example.com")
        XCTAssertNil(snapshot.note)
    }

    func testWindowLabels() {
        XCTAssertEqual(CodexRateLimitParser.windowLabel(minutes: nil, fallbackKey: "primary"), "Session")
        XCTAssertEqual(CodexRateLimitParser.windowLabel(minutes: 1440, fallbackKey: "primary"), "Daily")
        XCTAssertEqual(CodexRateLimitParser.windowLabel(minutes: 2880, fallbackKey: "primary"), "2-day")
        XCTAssertEqual(CodexRateLimitParser.windowLabel(minutes: 45, fallbackKey: "primary"), "45-minute")
    }
}

final class GrokBillingParserTests: XCTestCase {
    func testFreePlanWithoutPercentageReportsNoWindows() throws {
        let result = try JSONValue.parse("""
            {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-10-29T00:00:00+00:00","end":"2026-11-05T00:00:00+00:00"},
              "onDemandCap":{"val":0},"onDemandUsed":{"val":0},"prepaidBalance":{"val":0},"isUnifiedBillingUser":true},
             "subscription_tier":"Free"}
            """)

        let snapshot = try GrokBillingParser.parse(result, now: epoch)

        XCTAssertTrue(snapshot.windows.isEmpty)
        XCTAssertEqual(snapshot.plan, "Free")
        XCTAssertTrue(snapshot.note?.contains("does not report a usage percentage") ?? false)
        XCTAssertTrue(snapshot.note?.contains("Weekly period ends") ?? false)
    }

    func testUsesCreditPercentageAndPrepaidBalance() throws {
        let result = try JSONValue.parse("""
            {"config":{"creditUsagePercent":37.5,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-11-05T00:00:00Z"},
              "prepaidBalance":{"val":"1250"}},"subscription_tier":"SuperGrok"}
            """)

        let snapshot = try GrokBillingParser.parse(result, now: epoch)

        XCTAssertEqual(snapshot.windows.count, 1)
        let window = try XCTUnwrap(snapshot.windows.first)
        XCTAssertEqual(window.label, "Weekly")
        XCTAssertEqual(window.usedPercent, 37.5)
        XCTAssertEqual(window.resetsAt, date(2026, 11, 5))
        XCTAssertEqual(snapshot.note, "Prepaid balance: $12.50")
    }

    func testFallsBackToOnDemandSpend() throws {
        let result = try JSONValue.parse(#"{"config":{"onDemandCap":{"val":2000},"onDemandUsed":{"val":500}}}"#)

        let snapshot = try GrokBillingParser.parse(result, now: epoch)

        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 25)
    }
}

final class ClaudeUsageParserTests: XCTestCase {
    private let now = date(2026, 11, 2, 21, offsetHours: 9)

    func testParsesInlineReport() throws {
        let output = """
            You are currently using your subscription to power your Claude Code usage

            Current session: 23% used · resets 11pm (Asia/Tokyo)
            Current week (all models): 7% used · resets Nov 5, 7pm (Asia/Tokyo)
            Current week (Fable): 0% used · resets Nov 5, 7pm (Asia/Tokyo)

            What's contributing to your usage?
            Last 24h · 44 requests · 4 sessions
              54%  Turn off skills you don't use · 11k tokens per request
            """

        let snapshot = try ClaudeUsageParser.parse(output, now: now)

        XCTAssertEqual(snapshot.windows.count, 3)
        XCTAssertEqual(snapshot.windows[0].label, "Session")
        XCTAssertNil(snapshot.windows[0].group)
        XCTAssertEqual(snapshot.windows[0].usedPercent, 23)
        XCTAssertEqual(snapshot.windows[0].resetsAt, date(2026, 11, 2, 23, offsetHours: 9))
        XCTAssertEqual(snapshot.windows[1].group, "All models")
        XCTAssertEqual(snapshot.windows[1].label, "Weekly")
        XCTAssertEqual(snapshot.windows[1].resetsAt, date(2026, 11, 5, 19, offsetHours: 9))
        XCTAssertEqual(snapshot.windows[2].group, "Fable")
    }

    func testParsesPanelReportWithAnsi() throws {
        let output = "\u{1b}[1mCurrent session\u{1b}[0m\n  ████▌     9% used\n  Resets 10:30pm (Asia/Tokyo)\n\n"
            + "Current week (all models)\n  ██  60% left\n  Resets Nov 5 at 7pm (Asia/Tokyo)\n"

        let snapshot = try ClaudeUsageParser.parse(output, now: now)

        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows[0].usedPercent, 9)
        XCTAssertEqual(snapshot.windows[0].resetsAt, date(2026, 11, 2, 22, 30, offsetHours: 9))
        XCTAssertEqual(snapshot.windows[1].usedPercent, 40)
        XCTAssertEqual(snapshot.windows[1].resetsAt, date(2026, 11, 5, 19, offsetHours: 9))
    }

    func testTimeEarlierThanNowRollsToTomorrow() {
        let reset = ClaudeResetParser.tryParse("resets 8pm (Asia/Tokyo)", now: now)
        XCTAssertEqual(reset, date(2026, 11, 3, 20, offsetHours: 9))
    }

    func testDateWithYearAndFullMonth() {
        XCTAssertEqual(
            ClaudeResetParser.tryParse("Resets Nov 5, 2027 at 7:15am (Asia/Tokyo)", now: now),
            date(2027, 11, 5, 7, 15, offsetHours: 9))
        XCTAssertEqual(
            ClaudeResetParser.tryParse("resets November 5 (Asia/Tokyo)", now: now),
            date(2026, 11, 5, offsetHours: 9))
        XCTAssertNil(ClaudeResetParser.tryParse("resets soon", now: now))
    }

    func testPastDateWithoutYearRollsToNextYear() {
        XCTAssertEqual(
            ClaudeResetParser.tryParse("resets Jan 3, 9am (Asia/Tokyo)", now: now),
            date(2027, 1, 3, 9, offsetHours: 9))
    }

    func testErrorsAreSurfaced() {
        let error = assertThrowsUsageError(try ClaudeUsageParser.parse("Failed to load usage data: 401", now: now))
        XCTAssertTrue(error?.message.contains("could not load usage data") ?? false)
    }

    func testInsightPercentagesAreNotQuotas() {
        XCTAssertNotNil(assertThrowsUsageError(
            try ClaudeUsageParser.parse("What's contributing to your usage?\n  54% used by skills", now: now)))
    }

    func testUnknownOutputShowsFirstLine() {
        let error = assertThrowsUsageError(try ClaudeUsageParser.parse("\n  Something odd happened\nmore", now: now))
        XCTAssertEqual(error?.message, "Claude: Something odd happened")
    }
}

final class CliProcessTests: XCTestCase {
    func testParsesVersions() {
        XCTAssertEqual(CliProcess.parseVersion("2.1.325 (Claude Code)"), CliVersion(2, 1, 325))
        XCTAssertEqual(CliProcess.parseVersion("agy version 1.5"), CliVersion(1, 5, 0))
        XCTAssertNil(CliProcess.parseVersion("unknown"))
        XCTAssertTrue(CliVersion(1, 1, 10) < CliVersion(1, 1, 11))
    }

    func testFirstLineIsTrimmedAndBounded() {
        XCTAssertEqual(CliProcess.firstLine("\n \n  hello  \nworld"), "hello")
        XCTAssertEqual(CliProcess.firstLine(String(repeating: "a", count: 10), maxLength: 4), "aaaa…")
        XCTAssertNil(CliProcess.firstLine("  \n"))
    }

    func testRunsProcessAndCapturesOutput() async throws {
        let result = try await CliProcess.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"], timeout: 10)
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.standardOutput, "out\n")
        XCTAssertEqual(result.standardError, "err\n")
    }

    func testStdinIsClosed() async throws {
        // `cat` would wait forever if stdin stayed open.
        let result = try await CliProcess.run("/bin/cat", [], timeout: 10)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testTimeoutKillsTheProcessTree() async throws {
        let start = Date()
        do {
            _ = try await CliProcess.run("/bin/sh", ["-c", "sleep 30 & sleep 30"], timeout: 1)
            XCTFail("Expected a timeout")
        } catch let error as UsageProviderError {
            XCTAssertEqual(error.message, "sh timed out after 1s.")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testJsonRpcRoundTrip() async throws {
        // A tiny server: skips a notification, then answers with the request id.
        let script = """
            read line; echo '{"jsonrpc":"2.0","method":"note"}'; echo 'not json'
            id=$(echo "$line" | sed -E 's/.*"id":([0-9]+).*/\\1/')
            echo "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":$id,\\"result\\":{\\"ok\\":true}}"
            read line; id=$(echo "$line" | sed -E 's/.*"id":([0-9]+).*/\\1/')
            echo "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":$id,\\"error\\":{\\"code\\":-32601,\\"message\\":\\"nope\\"}}"
            """
        let result = try await withJsonRpcProcess("/bin/sh", ["-c", script], displayName: "test") { rpc -> JSONValue? in
            let first = try await rpc.request("hello", [:], timeout: 5)
            do {
                _ = try await rpc.request("missing", timeout: 5)
                XCTFail("Expected an error")
            } catch let error as JsonRpcError {
                XCTAssertEqual(error.code, JsonRpcError.methodNotFound)
                XCTAssertEqual(error.message, "missing: nope")
            }
            return first
        }
        XCTAssertEqual(result?["ok"], .bool(true))
    }

    func testJsonRpcReportsExit() async throws {
        do {
            _ = try await withJsonRpcProcess("/bin/sh", ["-c", "echo 'ERROR bad config' >&2; sleep 0.2"], displayName: "srv") { rpc in
                try await rpc.request("initialize", timeout: 5)
            }
            XCTFail("Expected an error")
        } catch let error as UsageProviderError {
            XCTAssertEqual(error.message, "srv exited: ERROR bad config")
        }
    }
}
