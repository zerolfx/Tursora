import Foundation
import Darwin

/// A private request file carries paths as NUL-delimited data. A FIFO wakes
/// zsh's line editor, never the terminal's input stream or a running command.
/// All ongoing file access lives on the serial queue, outside AppKit.
final class TerminalDirectorySync {
    enum State: Equatable { case waiting, synchronized, failed }
    struct Update: Equatable {
        let state: State
        let directory: URL?
        let requestedDirectory: URL?
        let isReady: Bool
    }

    let directory: URL
    let environment: [String: String]
    var onChange: ((Update) -> Void)?
    private let token: String
    private let queue = DispatchQueue(label: "tursora-terminal-directory-sync", qos: .utility)
    private var watcher: DispatchSourceFileSystemObject?
    private var wakeFD: Int32 = -1
    private var sequence: UInt64 = 0
    private var requestedDirectory: URL?
    private var reportedDirectory: URL?
    private var responseSequence: UInt64 = 0
    private var ready = false
    private var closed = false // queue confined
    private var invalidated = false // main thread confined

    static func make(shell: String, environment: [String: String]) throws -> TerminalDirectorySync? {
        guard URL(fileURLWithPath: shell).lastPathComponent == "zsh" else { return nil }
        return try TerminalDirectorySync(environment: environment)
    }

    private init(environment original: [String: String]) throws {
        token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tursora-shell-sync-" + token, isDirectory: true)
        var values = original
        values["TURSORA_USER_ZDOTDIR_SET"] = original["ZDOTDIR"] == nil ? "0" : "1"
        values["TURSORA_USER_ZDOTDIR"] = original["ZDOTDIR"] ?? ""
        values["ZDOTDIR"] = directory.path
        environment = values
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let fifo = directory.appendingPathComponent("wake").path
            guard mkfifo(fifo, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            wakeFD = open(fifo, O_RDWR | O_NONBLOCK | O_CLOEXEC)
            guard wakeFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try write(Self.startupScript, to: ".zshenv")
            try write(Self.integrationScript(directory: directory, token: token), to: "integration.zsh")
            let fd = open(directory.path, O_EVTONLY | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
            source.setEventHandler { [weak self] in self?.readResponse() }
            source.setCancelHandler { Darwin.close(fd) }
            watcher = source
            source.resume()
        } catch {
            if wakeFD >= 0 { Darwin.close(wakeFD) }
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func write(_ text: String, to name: String) throws {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func request(_ url: URL) {
        guard !invalidated, url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else { return }
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.sequence &+= 1
            self.requestedDirectory = url
            do {
                let data = Data("\(self.sequence)\0\(url.path)\0".utf8)
                let path = self.directory.appendingPathComponent("request")
                try data.write(to: path, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
                // One nonblocking byte is enough. A full pipe already contains
                // a wakeup; the latest atomic request replaces all older ones.
                var byte: UInt8 = 1
                _ = Darwin.write(self.wakeFD, &byte, 1)
                self.publish(.waiting)
            } catch { self.publish(.failed) }
        }
    }

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        onChange = nil
        queue.async { [self] in cleanup() }
    }

    deinit {
        // Normal panel teardown calls invalidate and the queue retains self
        // through cleanup. Also cover a prepared integration never installed.
        watcher?.cancel()
        if wakeFD >= 0 { Darwin.close(wakeFD) }
        try? FileManager.default.removeItem(at: directory)
    }

    private func cleanup() {
        guard !closed else { return }
        closed = true
        watcher?.cancel()
        watcher = nil
        if wakeFD >= 0 { Darwin.close(wakeFD); wakeFD = -1 }
        try? FileManager.default.removeItem(at: directory)
    }

    private func readResponse() {
        guard !closed, let data = try? Data(contentsOf: directory.appendingPathComponent("response")),
              let response = Self.parseResponse(data, token: token), response.sequence <= sequence,
              response.sequence >= responseSequence else { return }
        ready = true
        responseSequence = response.sequence
        reportedDirectory = response.directory
        let state: State = response.sequence == sequence ? (response.succeeded ? .synchronized : .failed) : .waiting
        publish(state)
    }

    private func publish(_ state: State) {
        let update = Update(state: state, directory: reportedDirectory, requestedDirectory: requestedDirectory, isReady: ready)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.invalidated else { return }
            self.onChange?(update)
        }
    }

    struct Response: Equatable {
        let sequence: UInt64
        let succeeded: Bool
        let directory: URL
    }
    static func parseResponse(_ data: Data, token: String) -> Response? {
        guard data.count <= 40_000, data.last == 0 else { return nil }
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.count == 5, String(data: fields[0], encoding: .utf8) == token,
              let number = String(data: fields[1], encoding: .utf8), let sequence = UInt64(number),
              fields[2] == Data("ok".utf8) || fields[2] == Data("failed".utf8),
              let path = String(data: fields[3], encoding: .utf8), path.hasPrefix("/"), path.utf8.count <= 32_768 else { return nil }
        return Response(sequence: sequence, succeeded: fields[2] == Data("ok".utf8), directory: URL(fileURLWithPath: path, isDirectory: true))
    }

    /// The one wrapper restores the real ZDOTDIR before sourcing .zshenv.
    /// Native zsh then reads .zprofile/.zshrc/.zlogin/.zlogout normally, including
    /// any ZDOTDIR or RCS changes made by the user's own startup files.
    static let startupScript = #"""
    builtin typeset _tursora_integration_file="$ZDOTDIR/integration.zsh"
    if [[ "$TURSORA_USER_ZDOTDIR_SET" == 1 ]]; then
      builtin export ZDOTDIR="$TURSORA_USER_ZDOTDIR"
    else
      builtin unset ZDOTDIR
    fi
    builtin unset TURSORA_USER_ZDOTDIR_SET TURSORA_USER_ZDOTDIR
    if [[ -r "${ZDOTDIR-$HOME}/.zshenv" ]]; then
      builtin source "${ZDOTDIR-$HOME}/.zshenv"
    fi
    if [[ -o interactive ]]; then
      builtin source "$_tursora_integration_file"
    fi
    builtin unset _tursora_integration_file
    """#

    static func integrationScript(directory: URL, token: String) -> String {
        // Only generated filenames and a hex token enter executable shell text;
        // navigation paths are read literally from the private request file.
        let quotedRoot = "'" + directory.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return #"""
        function _ts_TOKEN_report() {
          builtin emulate -L zsh
          builtin local number="$1" result="$2" responsefd
          [[ -d ROOT ]] || return 1
          builtin sysopen -w -o creat,trunc,cloexec,nofollow -m 600 -u responsefd ROOT/response.next || return 1
          builtin syswrite -o "$responsefd" 'TOKEN'$'\0'"$number"$'\0'"$result"$'\0'"$PWD"$'\0'
          builtin exec {responsefd}>&-
          builtin zf_mv -f -- ROOT/response.next ROOT/response
        }
        function _ts_TOKEN_apply() {
          builtin emulate -L zsh
          builtin local number target
          if [[ -r ROOT/request ]]; then
            { IFS= builtin read -r -d '' number && IFS= builtin read -r -d '' target } < ROOT/request || return 1
            [[ "$number" == <-> && "$target" == /* ]] || return 1
            if [[ "$number" != "$_ts_TOKEN_last" ]]; then
              if builtin cd -- "$target" 2>/dev/null; then
                _ts_TOKEN_last="$number"
                _ts_TOKEN_report "$number" ok
                return 0
              else
                _ts_TOKEN_report "$number" failed
                return 1
              fi
            fi
          fi
          _ts_TOKEN_report "${_ts_TOKEN_last:-0}" ok
        }
        function _ts_TOKEN_wake() {
          builtin emulate -L zsh
          builtin local bytes
          # Drain once (bounded 8192 bytes); ZLE calls again if more remain.
          builtin sysread -i "$_ts_TOKEN_fd" -t 0 bytes 2>/dev/null || return 0
          [[ "$CONTEXT" == start && -z "$BUFFER" ]] || return 0
          _ts_TOKEN_apply
          builtin zle reset-prompt
        }
        function _ts_TOKEN_prompt() {
          builtin emulate -L zsh
          [[ -d ROOT ]] || return 0
          if [[ -z "$_ts_TOKEN_fd" ]]; then
            builtin zmodload zsh/system || return 0
            # Load only prefixed names; never replace the user's mv command.
            builtin zmodload -F zsh/files b:zf_mv || return 0
            builtin typeset -g _ts_TOKEN_fd
            builtin sysopen -rw -o cloexec,nonblock -u _ts_TOKEN_fd ROOT/wake || return 0
            builtin zle -N _ts_TOKEN_wake
            builtin zle -F -w "$_ts_TOKEN_fd" _ts_TOKEN_wake
          fi
          _ts_TOKEN_apply
          return 0
        }
        builtin typeset -ga precmd_functions
        precmd_functions+=(_ts_TOKEN_prompt)
        """#.replacingOccurrences(of: "TOKEN", with: token).replacingOccurrences(of: "ROOT", with: quotedRoot)
    }
}
