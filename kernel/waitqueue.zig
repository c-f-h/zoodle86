const std = @import("std");
const task = @import("task.zig");

const WaitQueueNode = struct {
    task: *task.Task,
    lnode: std.SinglyLinkedList.Node = .{},

    fn fromNode(node: *std.SinglyLinkedList.Node) *WaitQueueNode {
        return @fieldParentPtr("lnode", node);
    }
};

/// A singly-linked list of tasks blocked waiting for some event.
pub const WaitQueue = struct {
    list: std.SinglyLinkedList = .{},
    allocator: std.mem.Allocator = undefined,

    /// Creates an empty WaitQueue backed by the given allocator.
    pub fn init(alloc: std.mem.Allocator) WaitQueue {
        return WaitQueue{
            .allocator = alloc,
        };
    }

    /// Returns true if no tasks are currently queued.
    pub fn empty(self: *WaitQueue) bool {
        return self.list.first == null;
    }

    /// Allocates a node for the given task and enqueues it at the front of the wait queue.
    pub fn add(self: *WaitQueue, pta: *task.Task) error{OutOfMemory}!void {
        const new_node = try self.allocator.create(WaitQueueNode);
        new_node.* = WaitQueueNode{
            .task = pta,
        };
        self.list.prepend(&new_node.lnode);
    }

    /// Wakes the first queued task, setting its kernel_yield return value to
    /// value.  Returns true if a waiter was found, false if the queue was empty.
    pub fn wakeOne(self: *WaitQueue, value: u32) bool {
        if (self.list.popFirst()) |node| {
            const wnode = WaitQueueNode.fromNode(node);
            wnode.task.wakeWithReturnValue(value);
            self.allocator.destroy(wnode);
            return true;
        }
        return false;
    }

    /// Wakes every queued task, setting each one's kernel_yield return value to
    /// value.  Returns true if at least one waiter was woken.
    pub fn wakeAll(self: *WaitQueue, value: u32) bool {
        var any_woken = false;
        while (self.list.popFirst()) |node| {
            const wnode = WaitQueueNode.fromNode(node);
            wnode.task.wakeWithReturnValue(value);
            self.allocator.destroy(wnode);
            any_woken = true;
        }
        return any_woken;
    }
};
