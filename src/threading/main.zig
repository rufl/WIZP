// WIZP threading — lightweight task system for non-blocking editor operations.
// Architecture:
//   Main thread:  Input handling + event dispatch
//   Render thread: 60fps terminal rendering (owns Terminal)
//   Worker pool:  N background threads for LSP, file I/O, AI, search
//
// Communication via lock-free SPSC channels (std.atomic.Queue).

const std = @import("std");

pub const Channel = @import("Channel.zig").Channel;
pub const WorkerResult = @import("Channel.zig").WorkerResult;
pub const AiChatResult = @import("Channel.zig").AiChatResult;
pub const AiCompletionResult = @import("Channel.zig").AiCompletionResult;
pub const WorkerPool = @import("Worker.zig").WorkerPool;

test {
    _ = Channel;
    _ = WorkerPool;
}
