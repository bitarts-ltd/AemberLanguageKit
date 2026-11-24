/**
    @file Process+ReadToEnd.swift
    @author Warren Mann
    @copyright Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Collects a child process's output without deadlocking.
    @details
    A child that writes more than a pipe's buffer (64 KB) blocks until
    the parent reads. Waiting for exit before reading, or reading one
    pipe to EOF while the other fills up, therefore hangs both sides.
    This extension drains stdout and stderr concurrently and only then
    waits for the process to exit. It also has `waitForExit`, the
    project's replacement for `waitUntilExit`.

    Async code uses `readToEnd(output:error:)` and `exited()`, which
    wait on a queue of their own rather than on one of Swift
    concurrency's few cooperative threads (a cmake or an Xcode build
    can take minutes), and stop the process when the task is
    cancelled.
*/

import Foundation

extension Process {

    /// @brief Where the async waits block, so they hold none of Swift
    /// concurrency's cooperative threads
    private static let waitQueue = DispatchQueue(
        label: "Aember.ProcessWait",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// @brief Read stdout and stderr to EOF, then wait for exit,
    /// without blocking a Swift concurrency thread.
    /// @detail
    /// Call after `run()`. `readToEndAndWait(output:error:)` runs on a
    /// queue of its own. Cancelling the task terminates the process;
    /// what it wrote until then is returned.
    /// @param output The pipe attached to `standardOutput`
    /// @param error The pipe attached to `standardError`, or nil if
    /// stderr is not piped
    /// @return The collected stdout and stderr data
    public func readToEnd(
        output: Pipe,
        error: Pipe?
    ) async -> (output: Data, error: Data) {
        await whileRunning {
            self.readToEndAndWait(output: output, error: error)
        }
    }

    /// @brief Wait for the process to exit without blocking a Swift
    /// concurrency thread.
    /// @detail
    /// Call after `run()`. Cancelling the task terminates the process.
    /// @return Nothing
    public func exited() async {
        await whileRunning {
            self.waitForExit()
        }
    }

    /// @brief Run a blocking wait on the wait queue, terminating the
    /// process if the task is cancelled meanwhile.
    /// @param wait The wait, which returns once the process has exited
    /// @return What the wait returned
    private func whileRunning<T>(_ wait: @escaping () -> T) async -> T {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Self.waitQueue.async {
                    continuation.resume(returning: wait())
                }
            }
        } onCancel: {
            if self.isRunning {
                self.terminate()
            }
        }
    }

    /// @brief Wait for the process to exit, polling `isRunning`.
    /// @detail
    /// Use this instead of `waitUntilExit`, which can sleep in its run
    /// loop past the process's exit until something else wakes the
    /// loop. Call after a successful `run()`. Polls often at first,
    /// since most waits follow a read that ended as the process exited,
    /// then less often. Blocks the calling thread without running its
    /// run loop, so call it off the main thread for anything slow.
    /// @return Nothing
    public func waitForExit() {
        var pause: useconds_t = 100
        while isRunning {
            usleep(pause)
            pause = min(pause * 2, 50_000)
        }
    }

    /// @brief Read stdout and stderr to EOF, then wait for exit.
    /// @detail
    /// Call after `run()`. Stderr is drained on a background queue while
    /// stdout is read on the calling thread, so neither pipe can fill up
    /// and block the child. Blocks the calling thread until the process
    /// exits.
    /// @param output The pipe attached to `standardOutput`
    /// @param error The pipe attached to `standardError`, or nil if
    /// stderr is not piped
    /// @return The collected stdout and stderr data
    public func readToEndAndWait(
        output: Pipe,
        error: Pipe?
    ) -> (output: Data, error: Data) {
        var errorData = Data()
        let group = DispatchGroup()

        if let error {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                errorData = error.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        waitForExit()

        return (outputData, errorData)
    }

    /// @brief Read stdout and stderr to EOF and wait for exit, for a
    /// limited time.
    /// @detail
    /// Call after `run()`. On timeout the process is terminated and
    /// nil returned at once; the reading goes on in the background
    /// until whatever holds the pipes (the process, or a child of it)
    /// lets go.
    /// @param output The pipe attached to `standardOutput`
    /// @param error The pipe attached to `standardError`, or nil if
    /// stderr is not piped
    /// @param timeout The most seconds to wait
    /// @return The collected stdout and stderr data, or nil on timeout
    public func readToEndAndWait(
        output: Pipe,
        error: Pipe?,
        timeout: TimeInterval
    ) -> (output: Data, error: Data)? {
        var result: (output: Data, error: Data)?
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            result = self.readToEndAndWait(output: output, error: error)
            finished.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            terminate()
            return nil
        }
        return result
    }
}
