import Foundation

/// Spawns the server binary in `--extract-batch` mode as a subprocess.
/// Each subprocess extracts a chunk of pages from a single PDF, serializes
/// the extracted text as JSON lines to stdout, and waits for SIGKILL.
/// The parent orchestrator reads JSON data from the pipe, kills the subprocess,
/// and returns the extracted pages to the caller. Disk I/O is never done by
/// the subprocess — only the orchestrator writes cache files.
struct SubprocessSpawner {

    /// Path to this binary, resolved at startup from CommandLine.arguments[0].
    static let executablePath: String = {
        let arg0 = CommandLine.arguments[0]
        if arg0.hasPrefix("/") { return arg0 }
        let cwd = FileManager.default.currentDirectoryPath
        return (cwd as NSString).appendingPathComponent(arg0)
    }()

    /// Timeout per chunk subprocess (seconds). 50 pages should extract in well under
    /// 2 minutes. If it takes longer, the PDF is likely corrupt or PDFKit is deadlocked.
    private static let timeoutSeconds = 120

    /// Result from a subprocess extraction attempt.
    struct ExtractionResult: Sendable {
        /// Pages successfully extracted (may be partial if subprocess timed out).
        let pages: [BatchExtractor.PageOutput]
        /// True if the subprocess completed normally (sent "DONE"). False on timeout/crash.
        /// When false, some pages in the requested range may be missing.
        let completed: Bool
    }

    /// Spawn a subprocess to extract pages [startPage, endPage] from a single PDF.
    /// Returns extracted page data + completion status. The subprocess only does PDFKit work;
    /// all disk I/O is the caller's responsibility.
    ///
    /// On timeout/crash, any pages that were successfully extracted before the failure
    /// are still returned (partial results). The caller can fill in placeholders for
    /// missing pages to record which pages failed extraction.
    ///
    /// Lifecycle (orchestrator-controlled):
    /// 1. Parent spawns subprocess with stdout → private Pipe
    /// 2. Subprocess extracts pages, writes JSON lines + "DONE" to stdout
    /// 3. Parent reads pipe, parses JSON → sends SIGKILL immediately
    /// 4. OS terminates process and reclaims ALL memory (including CoreGraphics leaks)
    /// 5. Parent returns parsed pages to caller for cache writing
    static func extractPages(
        vaultPath: String,
        pdfRelativePath: String,
        startPage: Int,
        endPage: Int
    ) async throws -> ExtractionResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [
            "--extract-batch",
            "--vault", vaultPath,
            "--pdf-path", pdfRelativePath,
            "--start-page", String(startPage),
            "--end-page", String(endPage)
        ]

        // Private pipe: subprocess stdout → parent reads JSON lines + "DONE" signal.
        // This is NOT the parent's stdout (JSON-RPC stream) — it's a private pipe.
        let pipe = Pipe()
        process.standardOutput = pipe
        // Subprocess stderr → our stderr (same Claude Desktop log)
        process.standardError = FileHandle.standardError

        let pid: pid_t
        do {
            try process.run()
            pid = process.processIdentifier
        } catch {
            throw error
        }

        // Read JSON lines from pipe, then SIGKILL. Orchestrator is always in charge.
        return await withCheckedContinuation { continuation in
            let didResume = NSLock()
            nonisolated(unsafe) var resumed = false

            @Sendable func finish(result: ExtractionResult) {
                didResume.lock()
                guard !resumed else { didResume.unlock(); return }
                resumed = true
                didResume.unlock()
                continuation.resume(returning: result)
            }

            // Background: read pipe for JSON lines + "DONE" signal, then kill
            DispatchQueue.global().async {
                let handle = pipe.fileHandleForReading
                var accumulated = Data()
                var foundDone = false

                // Read incrementally until "DONE" line or EOF (subprocess crash/timeout)
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break } // EOF — subprocess crashed or was killed
                    accumulated.append(chunk)
                    // Check for DONE as a complete line. JSON lines can't contain bare
                    // newlines (JSONEncoder escapes them), so \nDONE\n is unambiguous.
                    if let str = String(data: accumulated, encoding: .utf8),
                       str == "DONE\n" || str.contains("\nDONE\n") {
                        foundDone = true
                        break
                    }
                }

                // SIGKILL — orchestrator reclaims ALL memory including CoreGraphics leaks
                if process.isRunning {
                    kill(pid, SIGKILL)
                }
                process.waitUntilExit()

                // Always parse JSON lines — even on timeout/crash we salvage partial results.
                // Pages extracted before the failure are valid and shouldn't be discarded.
                var pages: [BatchExtractor.PageOutput] = []
                if !accumulated.isEmpty {
                    let decoder = JSONDecoder()
                    let newline = UInt8(ascii: "\n")
                    for line in accumulated.split(separator: newline) {
                        if let page = try? decoder.decode(
                            BatchExtractor.PageOutput.self, from: Data(line)
                        ) {
                            pages.append(page)
                        }
                        // Non-JSON lines (like "DONE") silently skipped by try?
                    }
                }

                finish(result: ExtractionResult(pages: pages, completed: foundDone))
            }

            // Timeout watchdog — kills hung subprocesses (corrupt PDFs, PDFKit deadlocks)
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds)) {
                guard process.isRunning else { return }
                fputs("SecondBrainMCP: subprocess PID \(pid) timed out after \(timeoutSeconds)s, sending SIGKILL\n", stderr)
                kill(pid, SIGKILL)
                // Pipe read will get EOF → finish() called from the reader above
            }
        }
    }
}
