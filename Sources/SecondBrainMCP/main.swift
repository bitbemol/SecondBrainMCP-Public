import Foundation

// SecondBrainMCP — Local MCP server for Markdown vault + PDF reference library
// stdout is reserved for JSON-RPC (StdioTransport). All output goes to stderr.

// Ignore SIGPIPE so broken-pipe writes return EPIPE instead of killing the process.
// Without this, when Claude Desktop closes the stdin/stdout pipes (on conversation end,
// sleep, etc.), the server gets silently terminated by the default SIGPIPE handler.
signal(SIGPIPE, SIG_IGN)

func log(_ message: String) {
    fputs("SecondBrainMCP: \(message)\n", stderr)
}

do {
    // 1. Parse CLI arguments into config
    let config = try ServerConfig.parse(arguments: CommandLine.arguments)

    switch config.mode {
    case .extractBatch(let batchConfig):
        // Subprocess mode: extract pages, serialize to stdout pipe, wait for SIGKILL.
        // Single responsibility: only PDFKit extraction. No disk I/O, no MCP, no git.
        let pages = BatchExtractor.extract(config: batchConfig)
        // Serialize each page as a JSON line to stdout (connected to parent's pipe).
        // Parent reads these, writes cache files, then SIGKILLs us.
        let encoder = JSONEncoder()
        for page in pages {
            if let data = try? encoder.encode(page) {
                data.withUnsafeBytes { _ = fwrite($0.baseAddress!, 1, $0.count, stdout) }
                fputc(0x0A, stdout) // newline separator
            }
        }
        // Signal completion to parent orchestrator.
        // fflush required: stdout is fully buffered when connected to a pipe.
        fputs("DONE\n", stdout)
        fflush(stdout)
        // Hang here — parent will SIGKILL us to reclaim ALL memory.
        // CoreGraphics background threads prevent natural process exit anyway.
        while true { sleep(UInt32.max) }

    case .server:
        // Normal MCP server mode
        log("vault: \(config.vaultPath)")
        log("read-only: \(config.readOnly)")
        log("extensions: \(config.allowedExtensions.sorted().joined(separator: ", "))")

        // 2. Ensure vault is a git repository (init or snapshot)
        let gitManager = GitManager(repoPath: config.vaultPath)
        try await gitManager.ensureRepository()
        log("git: repository ready")

        // 3. Start MCP server (blocks until client disconnects)
        try await MCPServerSetup.start(config: config, gitManager: gitManager)
    }

} catch {
    log("fatal: \(error)")
    exit(1)
}
