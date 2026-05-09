const std = @import("std");
const Node = std.SinglyLinkedList.Node;

const core = @import("core");

/// A singly linked FIFO (first in first out).
///
/// Uses the node type `std.SinglyLinkedList.Node` to allow the same node to be used in multiple list implementations.
///
/// Any functions on `std.SinglyLinkedList.Node` should not be called on any nodes in the list as they will not
/// correctly update the list.
pub const FIFO = struct {
    first_node: ?*Node = null,
    last_node: ?*Node = null,

    pub fn isEmpty(fifo: *const FIFO) bool {
        return fifo.first_node == null;
    }

    /// Removes the first node from and returns it.
    pub fn pop(fifo: *FIFO) ?*Node {
        const node = fifo.first_node orelse return null;
        if (core.is_debug) std.debug.assert(fifo.last_node != null);

        if (node == fifo.last_node) {
            if (core.is_debug) std.debug.assert(node.next == null);
            fifo.first_node = null;
            fifo.last_node = null;
        } else {
            fifo.first_node = node.next;
            node.next = null;
        }

        return node;
    }

    /// Append a node to the end.
    pub fn append(fifo: *FIFO, node: *Node) void {
        if (core.is_debug) std.debug.assert(node.next == null);

        if (fifo.last_node) |last| {
            if (core.is_debug) std.debug.assert(fifo.first_node != null);
            last.next = node;
        } else {
            fifo.first_node = node;
        }

        fifo.last_node = node;
    }
};

comptime {
    std.testing.refAllDecls(@This());
}
