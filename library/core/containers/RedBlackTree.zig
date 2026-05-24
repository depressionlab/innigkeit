const RedBlackTree = @This();
const std = @import("std");

root: ?*Node = null,
/// cached first node
first: ?*Node = null,
/// cached last node
last: ?*Node = null,
size: usize = 0,
/// Optional augmentation callback: called after every rotation.
/// `old` is the node that moved down; `new_root` is the node that moved up.
/// The callback must update any augmented values stored outside the `Node`.
on_rotate: ?*const fn (old: *Node, new_root: *Node) void = null,

const Color = enum(u1) {
    black,
    red,
};

const Side = enum(u1) {
    left,
    right,

    fn flip(self: @This()) @This() {
        return @enumFromInt(1 - @intFromEnum(self));
    }
};

const ColorSideAndParent = packed struct {
    color: Color = .black,
    side: Side = .left,
    isolated: bool = true,
    ptr: u61 = 0,
};

pub const Node = struct {
    left: ?*Node = null,
    right: ?*Node = null,
    // parent pointerless rb-trees
    // can't have simple+efficient iterators
    // and the memory saving is't very great
    extra: ColorSideAndParent = .{},

    comptime {
        std.debug.assert(@alignOf(Node) != 1);
    }

    fn setChild(self: *@This(), side: Side, node: ?*Node) void {
        if (side == .left) self.left = node else self.right = node;
    }

    fn setParent(self: *@This(), new: ?*Node) void {
        std.debug.assert(@as(u3, @truncate(@intFromPtr(new))) == 0);
        self.extra.ptr = @truncate(@intFromPtr(new) >> 3);
    }

    fn childPtr(self: *@This(), side: Side) *?*Node {
        const result = if (side == .left) &self.left else &self.right;
        std.debug.assert(result.* == null or result.*.?.extra.side == side);
        return result;
    }

    fn child(self: *@This(), side: Side) ?*Node {
        return self.childPtr(side).*;
    }

    pub fn parent(self: @This()) ?*Node {
        return @ptrFromInt(@as(u64, self.extra.ptr) << 3);
    }

    fn resetSide(self: *@This()) void {
        if (self.extra.ptr == 0) return;
        self.extra.side = sideOf(self);
    }

    // fn grandparent(self: @This()) ?*Node {
    //     const par = self.parent() orelse return null;
    //     return par.parent();
    // }

    // fn uncle(self: @This()) ?*Node {

    // }

    // fn sibling(self: @This()) ?*Node {
    //     const par = self.parent() orelse return null;
    //     return par.child(self.extra.side.flip());
    // }
};

pub const Entry = struct {
    parent: ?*Node,
    this: *?*Node,
};

/// O(log n) insert `node` into the tree using `comparator` to compare nodes,
/// returning the old node if there was a conflict
pub fn put(
    self: *@This(),
    comparator: *const fn (*const Node, *const Node) std.math.Order,
    node: *Node,
) ?*Node {
    const entry = self.getEntry(comparator, node);
    return self.putEntry(entry, node);
}

/// O(log n) remove the real node using a dummy node
pub fn findRemove(
    self: *@This(),
    comparator: *const fn (*const Node, *const Node) std.math.Order,
    node: *const Node,
) ?*Node {
    const entry = self.getEntry(comparator, node);
    return self.removeEntry(entry);
}

/// O(1) remove a node from the tree directly
pub fn remove(
    self: *@This(),
    node: *Node,
) void {
    const old = self.removeEntry(.{
        .parent = node.parent(),
        .this = self.entryOf(node.*),
    });
    std.debug.assert(old == node);
}

/// O(log n) look up the real node using a dummy node
pub fn get(
    self: *@This(),
    comparator: *const fn (*const Node, *const Node) std.math.Order,
    node: *const Node,
) ?*Node {
    return self.getEntry(comparator, node).this.*;
}

fn fixChildParentPointers(
    node: *Node,
) void {
    if (node.left) |left| left.setParent(node);
    if (node.right) |right| right.setParent(node);
}

/// O(1) insert, requires knowing the entry
pub fn putEntry(
    self: *@This(),
    entry: Entry,
    node: *Node,
) ?*Node {
    std.debug.assert(node.extra.isolated);

    if (takeAndReplace(entry.this, node)) |old| {
        // case 0 (old entry replaced)
        // std.debug.print("insert simple case 0\n", .{});
        node.* = old.*;
        old.* = undefined;
        old.extra.isolated = true;
        fixChildParentPointers(node);
        if (self.first == old) self.first = node;
        if (self.last == old) self.last = node;
        return old;
    }

    node.left = null;
    node.right = null;
    node.extra.color = .red;
    node.extra.isolated = false;
    node.setParent(entry.parent);
    node.resetSide();
    self.size += 1;
    if (self.first == null or (self.first == entry.parent and node.extra.side == .left)) self.first = node;
    if (self.last == null or (self.last == entry.parent and node.extra.side == .right)) self.last = node;
    self.rebalanceAfterPut(node);

    return null;
}

/// O(1) remove, requires knowing the entry
pub fn removeEntry(
    self: *@This(),
    /// pointer to a node pointer stored in a parent node or root
    old_entry: Entry,
) ?*Node {
    // defer self.verify(TestNode.cmp);

    var node = old_entry.this.* orelse {
        // case 0 (old entry null)
        // std.debug.print("insert simple case 0\n", .{});
        return null;
    };
    var node_entry = self.entryOf(node.*);
    self.size -= 1;

    std.debug.assert(!node.extra.isolated);

    if (node == self.first) {
        self.first = successor(self.first.?);
    }
    if (node == self.last) {
        self.last = predecessor(self.last.?);
    }

    while (true) {
        // std.debug.print("remove simple start (node=", .{});
        // TestNode.print(node);
        // if (node.parent()) |parent| {
        //     std.debug.print(", parent=", .{});
        //     TestNode.print(parent);
        // }
        // std.debug.print(")\n", .{});
        // self.debug(TestNode.print);
        std.debug.assert(node_entry.*.? == node);

        // simple cases

        if (node.left != null and node.right != null) {
            // std.debug.print("remove simple case 1\n", .{});
            const succ = leftmost(node.right.?);
            const succ_entry = self.entryOf(succ.*);
            std.debug.assert(succ.left == null);
            std.debug.assert(succ != node);
            std.debug.assert(succ_entry != node_entry);

            std.mem.swap(?*Node, succ_entry, node_entry);
            std.mem.swap(Node, succ, node);
            fixChildParentPointers(succ);
            fixChildParentPointers(node);
            node_entry = self.entryOf(node.*);
            continue;
        }

        if (node.left) |left| {
            // std.debug.print("remove simple case 2a\n", .{});
            std.debug.assert(node.extra.color == .black);
            std.debug.assert(left.extra.color == .red);
            node_entry.* = left;
            left.extra.color = .black;
            left.setParent(node.parent());
            left.resetSide();
            break;
        }

        if (node.right) |right| {
            // std.debug.print("remove simple case 2b\n", .{});
            std.debug.assert(node.extra.color == .black);
            std.debug.assert(right.extra.color == .red);
            node_entry.* = right;
            right.extra.color = .black;
            right.setParent(node.parent());
            right.resetSide();
            break;
        }

        if (node.parent() == null) {
            // std.debug.print("remove simple case 3\n", .{});
            self.root = null;
            break;
        }

        if (node.extra.color == .red) {
            // std.debug.print("remove simple case 4\n", .{});
            node_entry.* = null;
            break;
        }

        if (node.extra.color == .black) {
            node_entry.* = null;
            self.rebalanceAfterRemove(node);
            break;
        }
    }

    node.* = undefined;
    node.extra.isolated = true;
    return node;
}

fn takeAndReplace(dst: *?*Node, new: ?*Node) ?*Node {
    var tmp = new;
    std.mem.swap(?*Node, dst, &tmp);
    return tmp;
}

fn rebalanceAfterPut(
    self: *@This(),
    node_: *Node,
) void {
    // std.debug.print("rebalance (k=", .{});
    // TestNode.print(node_);
    // std.debug.print(")\n", .{});
    // defer self.verify(TestNode.cmp);
    // defer {
    //     std.debug.print("completed insert rebalance\n", .{});
    //     self.debug(TestNode.print);
    // }

    var node = node_;
    var parent = node.parent() orelse {
        return;
    };
    var dir: Side = undefined;
    var grandparent: *Node = undefined;
    var uncle: ?*Node = undefined;

    const State = enum {
        start,
        case_1,
        case_2,
        case_3,
        case_4,
        case_5,
        case_6,
    };

    loop: switch (State.start) {
        .start => {
            // std.debug.print("insert rebalance start (node=", .{});
            // TestNode.print(node);
            // std.debug.print(")\n", .{});
            // self.debug(TestNode.print);
            std.debug.assert(node.extra.color == .red);

            if (parent.extra.color == .black) {
                continue :loop .case_1;
            }

            grandparent = parent.parent() orelse {
                continue :loop .case_4;
            };

            dir = parent.extra.side;
            uncle = grandparent.child(dir.flip());
            std.debug.assert(uncle != parent);

            if (uncle == null or uncle.?.extra.color == .black) {
                if (node == parent.child(dir.flip())) {
                    continue :loop .case_5;
                }

                continue :loop .case_6;
            }

            continue :loop .case_2;
        },
        .case_1 => {
            // std.debug.print("insert rebalance case 1\n", .{});
            // self.debug(TestNode.print);
            return;
        },
        .case_2 => {
            // std.debug.print("insert rebalance case 2\n", .{});
            // self.debug(TestNode.print);
            parent.extra.color = .black;
            uncle.?.extra.color = .black;
            grandparent.extra.color = .red;
            node = grandparent;
            // std.debug.print("case 2\n", .{});
            // self.debug(TestNode.print);
            parent = node.parent() orelse {
                continue :loop .case_3;
            };
            continue :loop .start;
        },
        .case_3 => {
            // std.debug.print("insert rebalance case 3\n", .{});
            // self.debug(TestNode.print);
            return;
        },
        .case_4 => {
            // std.debug.print("insert rebalance case 4\n", .{});
            // self.debug(TestNode.print);
            parent.extra.color = .black;
            return;
        },
        .case_5 => {
            // std.debug.print("insert rebalance case 5\n", .{});
            // self.debug(TestNode.print);
            _ = self.rotate_node(parent, dir);
            node = parent;
            parent = grandparent.child(dir).?;
            continue :loop .case_6;
        },
        .case_6 => {
            // std.debug.print("insert rebalance case 6\n", .{});
            // self.debug(TestNode.print);
            _ = self.rotate_node(grandparent, dir.flip());
            parent.extra.color = .black;
            grandparent.extra.color = .red;
            return;
        },
    }
}

fn rebalanceAfterRemove(
    self: *@This(),
    node_: *Node,
) void {
    // self.debug(TestNode.print);
    // defer self.verify(TestNode.cmp);
    // defer {
    //     std.debug.print("completed remove rebalance\n", .{});
    //     self.debug(TestNode.print);
    // }

    var node = node_;
    var parent = node.parent().?;
    var side = node.extra.side;

    const State = enum {
        start,
        case_1,
        case_2,
        case_3,
        case_4,
        case_5,
        case_6,
    };

    var sibling: *Node = undefined;
    var distant_nephew: ?*Node = undefined;
    var close_nephew: ?*Node = undefined;

    loop: switch (State.start) {
        .start => {
            // std.debug.print("remove rebalance start (node=", .{});
            // TestNode.print(node);
            // std.debug.print(")\n", .{});

            sibling = parent.child(side.flip()).?;
            distant_nephew = sibling.child(side.flip());
            close_nephew = sibling.child(side);

            if (sibling.extra.color == .red) {
                continue :loop .case_3;
            }

            if (distant_nephew != null and
                distant_nephew.?.extra.color == .red)
            {
                continue :loop .case_6;
            }
            if (close_nephew != null and
                close_nephew.?.extra.color == .red)
            {
                continue :loop .case_5;
            }

            // // ??? how can the parent be null randomly
            // if (parent == null) {
            //     continue :loop .case_1;
            // }

            if (parent.extra.color == .red) {
                continue :loop .case_4;
            }

            continue :loop .case_2;
        },
        .case_1 => {
            // std.debug.print("remove rebalance case 1\n", .{});
            return;
        },
        .case_2 => {
            // std.debug.print("remove rebalance case 2\n", .{});
            sibling.extra.color = .red;
            node = parent;
            parent = node.parent() orelse {
                return;
            };
            side = node.extra.side;
            continue :loop .start;
        },
        .case_3 => {
            // std.debug.print("remove rebalance case 3\n", .{});
            _ = self.rotate_node(parent, side);
            parent.extra.color = .red;
            sibling.extra.color = .black;
            sibling = close_nephew.?;

            distant_nephew = sibling.child(side.flip());
            if (distant_nephew != null and
                distant_nephew.?.extra.color == .red)
            {
                continue :loop .case_6;
            }
            close_nephew = sibling.child(side);
            if (close_nephew != null and
                close_nephew.?.extra.color == .red)
            {
                continue :loop .case_5;
            }

            continue :loop .case_4;
        },
        .case_4 => {
            // std.debug.print("remove rebalance case 4\n", .{});
            sibling.extra.color = .red;
            parent.extra.color = .black;
            return;
        },
        .case_5 => {
            // std.debug.print("remove rebalance case 5 (side={any})\n", .{side.flip()});
            _ = self.rotate_node(sibling, side.flip());
            sibling.extra.color = .red;
            close_nephew.?.extra.color = .black;
            distant_nephew = sibling;
            sibling = close_nephew.?;
            continue :loop .case_6;
        },
        .case_6 => {
            // std.debug.print("remove rebalance case 6 (side={any})\n", .{side});
            // std.debug.print("n={} p={} gp={?} s={} dn={?} cn={?}\n", .{
            //     TestNode.of(node).key,
            //     TestNode.of(parent).key,
            //     TestNode.keyOpt(parent.parent()),
            //     TestNode.of(sibling).key,
            //     TestNode.keyOpt(distant_nephew),
            //     TestNode.keyOpt(close_nephew),
            // });
            _ = self.rotate_node(parent, side);
            sibling.extra.color = parent.extra.color;
            parent.extra.color = .black;
            distant_nephew.?.extra.color = .black;
            return;
        },
    }
}

/// O(log n) lookup
pub fn getEntry(
    self: *@This(),
    comparator: *const fn (*const Node, *const Node) std.math.Order,
    node: *const Node,
) Entry {
    var entry: Entry = .{
        .parent = null,
        .this = &self.root,
    };
    while (entry.this.*) |cur| {
        const next = switch (comparator(node, cur)) {
            .gt => &cur.right,
            .lt => &cur.left,
            .eq => break,
        };
        entry.parent = cur;
        entry.this = next;
    }
    return entry;
}

/// O(log n) lookup
/// can be used to find the exact entry
/// or the smallest entry larger than `node`
pub fn getEntryOrLarger(
    self: *@This(),
    comparator: *const fn (*const Node, *const Node) std.math.Order,
    node: *const Node,
) ?*Node {
    var cur = self.root orelse return null;
    while (true) {
        switch (comparator(node, cur)) {
            .gt => cur = cur.right orelse return advance(cur, .right),
            .lt => cur = cur.left orelse return cur,
            .eq => break,
        }
    }
    return cur;
}

/// O(log n) lookup
/// can be used to find the exact entry
/// or the largest entry smaller than `node`
pub fn getEntryOrSmaller(
    self: *@This(),
    comparator: *const fn (*const Node, *const Node) std.math.Order,
    node: *const Node,
) ?*Node {
    var cur = self.root orelse return null;
    while (true) {
        switch (comparator(node, cur)) {
            .gt => cur = cur.right orelse return cur,
            .lt => cur = cur.left orelse return advance(cur, .left),
            .eq => break,
        }
    }
    return cur;
}

/// get a pointer to the pointer that points to this node
fn entryOf(
    self: *@This(),
    node: Node,
) *?*Node {
    const parent = node.parent() orelse {
        return &self.root;
    };
    return parent.childPtr(node.extra.side);
}

pub fn leftmost(
    subtree: *Node,
) *Node {
    return repeat(subtree, .left);
}

pub fn rightmost(
    subtree: *Node,
) *Node {
    return repeat(subtree, .right);
}

pub fn repeat(
    subtree: *Node,
    side: Side,
) *Node {
    var cur = subtree;
    while (cur.child(side)) |next| {
        cur = next;
    }
    return cur;
}

pub fn predecessor(
    node: *Node,
) ?*Node {
    return advance(node, .left);
}

pub fn successor(
    node: *Node,
) ?*Node {
    return advance(node, .right);
}

pub fn advance(
    node: *Node,
    dir: Side,
) ?*Node {
    var cur = node;
    if (cur.child(dir)) |subtree| {
        return repeat(subtree, dir.flip());
    }
    // go back up as long as the current node
    // is on the same side of the subtree
    while (true) {
        const is_same = cur.extra.side == dir;
        cur = cur.parent() orelse return null;
        if (!is_same) break;
    }
    return cur;
}

fn sideOf(
    node: *const Node,
) Side {
    if (node.parent().?.left == node) {
        return .left;
    } else {
        return .right;
    }
}

fn rotate_node(self: *@This(), node: *Node, side: Side) *Node {
    const subtree_parent = node.parent();
    const new_subtree_root = node.child(side.flip()).?;

    const new_child = new_subtree_root.child(side);
    node.setChild(side.flip(), new_child);
    if (new_child) |new_child_| {
        new_child_.setParent(node);
        new_child_.resetSide();
    }

    new_subtree_root.setChild(side, node);
    new_subtree_root.setParent(subtree_parent);
    node.setParent(new_subtree_root);
    if (subtree_parent) |subtree_parent_| {
        const subtree_dir = if (subtree_parent_.left == node)
            Side.left
        else
            Side.right;
        subtree_parent_.setChild(subtree_dir, new_subtree_root);
    } else {
        self.root = new_subtree_root;
    }

    new_subtree_root.resetSide();
    node.resetSide();
    if (self.on_rotate) |cb|
        cb(node, new_subtree_root);
    return new_subtree_root;
}

pub const Iterator = struct {
    head: ?*Node = null,
    tail: ?*Node = null,

    pub fn next(
        self: *@This(),
    ) ?*Node {
        const cur = self.head orelse return null;
        if (self.head == self.tail) self.* = .{};
        self.head = successor(cur);
        return cur;
    }

    pub fn nextBack(
        self: *@This(),
    ) ?*Node {
        const cur = self.tail orelse return null;
        if (self.head == self.tail) self.* = .{};
        self.tail = predecessor(cur);
        return cur;
    }
};

pub fn iterator(
    self: *const @This(),
) Iterator {
    return .{
        .head = self.first,
        .tail = self.last,
    };
}

pub fn debug(
    self: *const @This(),
    format: *const fn (*const Node, writer: *std.Io.Writer) std.Io.Writer.Error!void,
) void {
    std.debug.print("{f}", .{self.display(format)});
}

pub fn display(
    self: *const @This(),
    formatNode: *const fn (*const Node, writer: *std.Io.Writer) std.Io.Writer.Error!void,
) Display {
    return .{ .tree = self, .formatNode = formatNode };
}

pub const Display = struct {
    tree: *const RedBlackTree,
    formatNode: *const fn (*const Node, writer: *std.Io.Writer) std.Io.Writer.Error!void,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        var prefix = Rope{};
        try self.formatInner(writer, self.tree.root, &prefix, false);
    }

    fn formatInner(
        self: @This(),
        writer: *std.Io.Writer,
        node_: ?*const Node,
        prefix: *Rope,
        is_left: bool,
    ) std.Io.Writer.Error!void {
        try writer.print("\x1b[90m", .{});
        try prefix.print(writer);

        const hori =
            if (is_left) "├────" else "└────";
        try writer.print("{s}", .{hori});

        const node = node_ orelse {
            try writer.print("\x1b[30mNIL\x1b[0m\n", .{});
            return;
        };

        try writer.print("{s}", .{if (node.extra.color == .red) "\x1b[31m" else "\x1b[30m"});
        try self.formatNode(node, writer);
        try writer.print("{s}{s}\x1b[0m\n", .{
            if (node == self.tree.root or (node.extra.side == .left) == is_left) "" else " wrong side",
            if (node == self.tree.root or node.parent().?.child(node.extra.side) == node) "" else " wrong parent",
        });

        var vert =
            prefix.push(if (is_left) "│    " else "     ");
        try self.formatInner(writer, node.left, &vert, true);
        try self.formatInner(writer, node.right, &vert, false);
    }
};

const Rope = struct {
    prev: ?*@This() = null,
    next: ?*@This() = null,
    this: []const u8 = "",

    fn print(
        self: *@This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        // construct next chain
        var cur = self;
        cur.next = null;
        while (cur.prev) |prev| {
            prev.next = cur;
            cur = prev;
        }
        // print using the next chain
        while (cur.next) |next| {
            try writer.print("{s}", .{cur.this});
            cur = next;
        }
        try writer.print("{s}", .{cur.this});
        // // print in reverse
        // var cur = self;
        // while (cur.prev) |next| {
        //     try writer.print("{s}", .{cur.this});
        //     cur = next;
        // }
    }

    fn push(
        self: *@This(),
        part: []const u8,
    ) Rope {
        return .{
            .prev = self,
            .this = part,
        };
    }
};

pub fn verify(
    self: *const @This(),
    comparator: *const fn (*const Node, *const Node) std.math.Order,
) void {
    const root = self.root orelse {
        std.debug.assert(self.first == null);
        std.debug.assert(self.last == null);
        return;
    };
    std.debug.assert(root.parent() == null);
    std.debug.assert(leftmost(root) == self.first);
    std.debug.assert(rightmost(root) == self.last);

    var black_height: ?usize = null;
    var node_count: usize = 0;
    verifyRecurse(
        comparator,
        root,
        0,
        &black_height,
        &node_count,
    );
    std.debug.assert(node_count == self.size);
}

fn verifyRecurse(
    comparator: *const fn (*const Node, *const Node) std.math.Order,
    _cur: ?*const Node,
    black_depth: usize,
    black_height: *?usize,
    node_count: *usize,
) void {
    if (_cur) |cur| {
        node_count.* += 1;

        std.debug.assert(!cur.extra.isolated);

        if (cur.left) |left| {
            std.debug.assert(comparator(left, cur) == .lt);
            std.debug.assert(left.parent() == cur);
            std.debug.assert(cur.extra.color == .black or left.extra.color == .black);
            std.debug.assert(left.extra.side == .left);
        }
        if (cur.right) |right| {
            std.debug.assert(comparator(cur, right) == .lt);
            std.debug.assert(right.parent() == cur);
            std.debug.assert(cur.extra.color == .black or right.extra.color == .black);
            std.debug.assert(right.extra.side == .right);
        }

        const next_black_depth = black_depth + @intFromBool(cur.extra.color == .black);
        verifyRecurse(
            comparator,
            cur.left,
            next_black_depth,
            black_height,
            node_count,
        );
        verifyRecurse(
            comparator,
            cur.right,
            next_black_depth,
            black_height,
            node_count,
        );
    } else if (black_height.*) |known_black_depth| {
        // black height of every leaf node has to be the same
        std.debug.assert(known_black_depth == black_depth + 1);
    } else {
        black_height.* = black_depth + 1;
    }
}

// test cases stolen from Rust's BTreeMap doctests

const TestNode = struct {
    key: u8,
    value: u8 = undefined,
    node: RedBlackTree.Node = .{},

    fn keyOpt(
        node: ?*const RedBlackTree.Node,
    ) ?u8 {
        return (ofOpt(node) orelse return null).key;
    }

    fn valueOpt(
        node: ?*const RedBlackTree.Node,
    ) ?u8 {
        return (ofOpt(node) orelse return null).value;
    }

    fn ofOpt(
        node: ?*const RedBlackTree.Node,
    ) ?*const @This() {
        return @fieldParentPtr("node", node orelse return null);
    }

    fn of(
        node: *const RedBlackTree.Node,
    ) *const @This() {
        return @fieldParentPtr("node", node);
    }

    fn cmp(
        lhs_node: *const RedBlackTree.Node,
        rhs_node: *const RedBlackTree.Node,
    ) std.math.Order {
        return std.math.order(of(lhs_node).key, of(rhs_node).key);
    }

    pub fn format(
        self: *const @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        return writer.print(".{{ .key = {}, .value = {} }}", .{
            self.key, self.value,
        });
    }

    fn print(
        node: *const RedBlackTree.Node,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        return writer.print("{d}", .{of(node).key});
    }
};

test "node size/align" {
    try std.testing.expectEqual(@sizeOf(RedBlackTree.Node), @sizeOf(usize) * 3);
    try std.testing.expectEqual(@alignOf(RedBlackTree.Node), @sizeOf(usize));
}

test "insert" {
    var map: RedBlackTree = .{};
    var node_a: TestNode = .{ .key = 1, .value = 'a' };
    var node_b: TestNode = .{ .key = 1, .value = 'b' };

    map.verify(TestNode.cmp);
    try std.testing.expectEqual(0, map.size);

    var old = map.put(TestNode.cmp, &node_a.node);
    try std.testing.expectEqual(null, old);

    map.verify(TestNode.cmp);
    try std.testing.expectEqual(1, map.size);

    old = map.put(TestNode.cmp, &node_b.node);
    try std.testing.expectEqual(&node_a.node, old);

    map.verify(TestNode.cmp);
    try std.testing.expectEqual(1, map.size);
}

test "remove" {
    var map: RedBlackTree = .{};
    // inserted node
    var node_a: TestNode = .{ .key = 1, .value = 'a' };
    // dummy node for access
    var node_b: TestNode = .{ .key = 1, .value = 'b' };

    map.verify(TestNode.cmp);
    try std.testing.expectEqual(0, map.size);

    const old = map.put(TestNode.cmp, &node_a.node);
    try std.testing.expectEqual(null, old);

    map.verify(TestNode.cmp);
    try std.testing.expectEqual(1, map.size);

    var removed = map.findRemove(TestNode.cmp, &node_b.node);
    try std.testing.expectEqual(&node_a.node, removed);

    map.verify(TestNode.cmp);
    try std.testing.expectEqual(0, map.size);

    removed = map.findRemove(TestNode.cmp, &node_b.node);
    try std.testing.expectEqual(null, removed);

    map.verify(TestNode.cmp);
    try std.testing.expectEqual(0, map.size);
}

test "get" {
    var map: RedBlackTree = .{};
    // inserted node
    var node_a: TestNode = .{ .key = 1, .value = 'a' };
    // dummy nodes for access
    var node_b: TestNode = .{ .key = 1, .value = 'a' };
    var node_c: TestNode = .{ .key = 2, .value = 'b' };

    const old = map.put(TestNode.cmp, &node_a.node);
    try std.testing.expectEqual(null, old);

    var found = map.get(TestNode.cmp, &node_b.node);
    try std.testing.expectEqual(&node_a.node, found);
    found = map.get(TestNode.cmp, &node_c.node);
    try std.testing.expectEqual(null, found);

    // std.debug.panic("{f}\n", .{map.display(TestNode.print)});
}

test "iterator" {
    var map: RedBlackTree = .{};
    var node_a: TestNode = .{ .key = 1, .value = 'a' };
    var node_b: TestNode = .{ .key = 2, .value = 'b' };
    var node_c: TestNode = .{ .key = 3, .value = 'c' };
    var node_d: TestNode = .{ .key = 4, .value = 'd' };

    // insert out of order
    const a = map.put(TestNode.cmp, &node_d.node);
    try std.testing.expectEqual(null, a);
    const b = map.put(TestNode.cmp, &node_b.node);
    try std.testing.expectEqual(null, b);
    const c = map.put(TestNode.cmp, &node_a.node);
    try std.testing.expectEqual(null, c);
    const d = map.put(TestNode.cmp, &node_c.node);
    try std.testing.expectEqual(null, d);

    try std.testing.expectEqual(1, TestNode.keyOpt(map.first));
    try std.testing.expectEqual(4, TestNode.keyOpt(map.last));

    // iterate in order
    var iter = map.iterator();
    try std.testing.expectEqual(1, TestNode.ofOpt(iter.next()).?.key);
    try std.testing.expectEqual(2, TestNode.ofOpt(iter.next()).?.key);
    try std.testing.expectEqual(3, TestNode.ofOpt(iter.next()).?.key);
    try std.testing.expectEqual(4, TestNode.ofOpt(iter.next()).?.key);
    try std.testing.expectEqual(null, iter.next());

    // iterate in reverse
    iter = map.iterator();
    try std.testing.expectEqual(4, TestNode.ofOpt(iter.nextBack()).?.key);
    try std.testing.expectEqual(3, TestNode.ofOpt(iter.nextBack()).?.key);
    try std.testing.expectEqual(2, TestNode.ofOpt(iter.nextBack()).?.key);
    try std.testing.expectEqual(1, TestNode.ofOpt(iter.nextBack()).?.key);
    try std.testing.expectEqual(null, iter.next());

    // mixed iteration
    iter = map.iterator();
    try std.testing.expectEqual(1, TestNode.ofOpt(iter.next()).?.key);
    try std.testing.expectEqual(4, TestNode.ofOpt(iter.nextBack()).?.key);
    try std.testing.expectEqual(2, TestNode.ofOpt(iter.next()).?.key);
    try std.testing.expectEqual(3, TestNode.ofOpt(iter.nextBack()).?.key);
    try std.testing.expectEqual(null, iter.next());
}

fn expectKvEq(expected: anytype, actual: anytype) !void {
    if ((expected == null) != (actual == null))
        return error.TestExpectedEqual;

    if (expected == null) return;

    try std.testing.expectEqual(expected.?.key, actual.?.key);
    try std.testing.expectEqual(expected.?.value, actual.?.value);
}

fn dumpContents(hashmap: std.AutoHashMapUnmanaged(u8, u8), treemap: RedBlackTree) void {
    var it1 = hashmap.iterator();
    std.debug.print("hashmap: [", .{});
    if (it1.next()) |next| std.debug.print("{}", .{next.key_ptr.*});
    while (it1.next()) |next| std.debug.print(", {}", .{next.key_ptr.*});
    std.debug.print("]\n", .{});

    var it2 = treemap.iterator();
    std.debug.print("treemap: [", .{});
    if (it2.next()) |next| std.debug.print("{}", .{TestNode.of(next).key});
    while (it2.next()) |next| std.debug.print(", {}", .{TestNode.of(next).key});
    std.debug.print("]\n", .{});

    treemap.debug(TestNode.print);
}

test "fuzz" {
    const op_limit = 128;
    const key_limit = 64;

    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) anyerror!void {
            if (!@import("builtin").fuzz) return;

            var input = smith.in;

            const TreeMap = RedBlackTree;
            const HashMap = std.AutoHashMapUnmanaged(u8, u8);

            var gpa = std.heap.DebugAllocator(.{}){};
            const alloc = gpa.allocator();
            defer _ = gpa.detectLeaks();

            var nodes: std.heap.MemoryPool(TestNode) = .init(alloc);
            defer nodes.deinit();

            var treemap: TreeMap = .{};
            var hashmap: HashMap = .{};
            defer hashmap.deinit(alloc);

            var ops_left: u8 = op_limit;

            while (true) {
                if (ops_left == 0) break;
                ops_left -= 1;

                if (input.len < 1) break;
                const opcode: u8 = input[0];
                input = input[1..];

                switch (@as(u3, @truncate(opcode % 8))) {
                    0 => {
                        if (input.len < 1) break;
                        const key = std.mem.readInt(u8, input[0..1], .little) % key_limit;
                        input = input[1..];

                        if (input.len < 1) break;
                        const val = std.mem.readInt(u8, input[0..1], .little);
                        input = input[1..];

                        std.debug.print("fetchPut(key={}, val={}, size={})\n", .{
                            key,
                            val,
                            treemap.size,
                        });

                        const node: *TestNode = try nodes.create();
                        node.* = .{ .key = key, .value = val };

                        const v1 = treemap.put(TestNode.cmp, &node.node);
                        const v2 = try hashmap.fetchPut(alloc, key, val);

                        if (v1) |old| std.debug.assert(old.extra.isolated);

                        std.debug.print("hashmap -> {any}\n", .{v2});
                        std.debug.print("rb-tree -> {?f}\n", .{TestNode.ofOpt(v1)});
                        dumpContents(hashmap, treemap);

                        try expectKvEq(v2, TestNode.ofOpt(v1));
                    },
                    1 => {
                        if (input.len < 1) break;
                        const key = std.mem.readInt(u8, input[0..1], .little) % key_limit;
                        input = input[1..];

                        std.debug.print("fetchRemove(key={}, size={})\n", .{
                            key,
                            treemap.size,
                        });

                        const fetcher: TestNode = .{ .key = key };
                        const v1 = treemap.findRemove(TestNode.cmp, &fetcher.node);
                        const v2 = hashmap.fetchRemove(key);

                        if (v1) |old| std.debug.assert(old.extra.isolated);

                        std.debug.print("hashmap -> {any}\n", .{v2});
                        std.debug.print("rb-tree -> {?f}\n", .{TestNode.ofOpt(v1)});
                        dumpContents(hashmap, treemap);

                        try expectKvEq(v2, TestNode.ofOpt(v1));
                    },
                    2 => {
                        if (input.len < 1) break;
                        const key = std.mem.readInt(u8, input[0..1], .little) % key_limit;
                        input = input[1..];

                        std.debug.print("get(key={}, size={})\n", .{
                            key,
                            treemap.size,
                        });

                        const fetcher: TestNode = .{ .key = key };
                        const v1 = treemap.get(TestNode.cmp, &fetcher.node);
                        const v2 = hashmap.get(key);

                        if (v1) |old| std.debug.assert(!old.extra.isolated);

                        std.debug.print("hashmap -> {any}\n", .{v2});
                        std.debug.print("rb-tree -> {any}\n", .{TestNode.valueOpt(v1)});
                        dumpContents(hashmap, treemap);

                        try std.testing.expectEqual(v2, TestNode.valueOpt(v1));
                    },
                    3 => {
                        if (treemap.first) |first| {
                            const v1 = TestNode.of(first);

                            std.debug.print("popFirst(key={}, size={})\n", .{
                                v1.key,
                                treemap.size,
                            });

                            treemap.remove(first);
                            const v2 = hashmap.fetchRemove(v1.key);

                            std.debug.assert(first.extra.isolated);

                            std.debug.print("hashmap -> {any}\n", .{v2});
                            std.debug.print("rb-tree -> {f}\n", .{v1});
                            dumpContents(hashmap, treemap);

                            try expectKvEq(v2, @as(?*const TestNode, v1));
                        } else {
                            try std.testing.expectEqual(0, treemap.size);
                        }
                    },
                    4 => {
                        if (treemap.last) |last| {
                            const v1 = TestNode.of(last);

                            std.debug.print("popLast(key={}, size={})\n", .{
                                v1.key,
                                treemap.size,
                            });

                            treemap.remove(last);
                            const v2 = hashmap.fetchRemove(v1.key);

                            std.debug.assert(last.extra.isolated);

                            std.debug.print("hashmap -> {any}\n", .{v2});
                            std.debug.print("rb-tree -> {f}\n", .{v1});
                            dumpContents(hashmap, treemap);

                            try expectKvEq(v2, @as(?*const TestNode, v1));
                        } else {
                            try std.testing.expectEqual(0, treemap.size);
                        }
                    },
                    5 => {
                        std.debug.print("clear(size={})\n", .{
                            treemap.size,
                        });

                        var m = treemap;
                        while (m.first) |first| {
                            m.remove(first);
                            nodes.destroy(@constCast(TestNode.of(first)));
                        }

                        treemap = .{};
                        hashmap.clearRetainingCapacity();

                        dumpContents(hashmap, treemap);
                    },
                    6 => {
                        if (input.len < 1) break;
                        const key = std.mem.readInt(u8, input[0..1], .little) % key_limit;
                        input = input[1..];

                        std.debug.print("getEntryOrSmaller(key={}, size={})\n", .{
                            key,
                            treemap.size,
                        });

                        const fetcher: TestNode = .{ .key = key };
                        const v1 = treemap.getEntryOrSmaller(TestNode.cmp, &fetcher.node);
                        var it = hashmap.iterator();
                        var v2: ?u8 = null;
                        while (it.next()) |next| {
                            if (next.key_ptr.* > key) continue;
                            if (v2 == null or next.key_ptr.* > v2.?)
                                v2 = next.key_ptr.*;
                        }

                        if (v1) |old| std.debug.assert(!old.extra.isolated);

                        std.debug.print("hashmap -> {any}\n", .{v2});
                        std.debug.print("rb-tree -> {any}\n", .{TestNode.keyOpt(v1)});
                        dumpContents(hashmap, treemap);

                        try std.testing.expectEqual(v2, TestNode.keyOpt(v1));
                    },
                    7 => {
                        if (input.len < 1) break;
                        const key = std.mem.readInt(u8, input[0..1], .little) % key_limit;
                        input = input[1..];

                        std.debug.print("getEntryOrLarger(key={}, size={})\n", .{
                            key,
                            treemap.size,
                        });

                        const fetcher: TestNode = .{ .key = key };
                        const v1 = treemap.getEntryOrLarger(TestNode.cmp, &fetcher.node);
                        var it = hashmap.iterator();
                        var v2: ?u8 = null;
                        while (it.next()) |next| {
                            if (next.key_ptr.* < key) continue;
                            if (v2 == null or next.key_ptr.* < v2.?)
                                v2 = next.key_ptr.*;
                        }

                        if (v1) |old| std.debug.assert(!old.extra.isolated);

                        std.debug.print("hashmap -> {any}\n", .{v2});
                        std.debug.print("rb-tree -> {any}\n", .{TestNode.keyOpt(v1)});
                        dumpContents(hashmap, treemap);

                        try std.testing.expectEqual(v2, TestNode.keyOpt(v1));
                    },
                    // else => unreachable,
                }

                {
                    // check that all treemap entries are in the hashmap and are the same
                    var it = treemap.iterator();
                    while (it.next()) |next_| {
                        const next = TestNode.of(next_);
                        const expected_val = hashmap.get(next.key).?;
                        try std.testing.expectEqual(expected_val, next.value);
                    }
                }
                {
                    // check that all hashmap entries are in the treemap and are the same
                    var it = hashmap.iterator();
                    while (it.next()) |next_| {
                        const fetcher: TestNode = .{ .key = next_.key_ptr.* };
                        const expected = TestNode.of(treemap.get(TestNode.cmp, &fetcher.node).?);
                        try std.testing.expectEqual(expected.key, next_.key_ptr.*);
                        try std.testing.expectEqual(expected.value, next_.value_ptr.*);
                    }
                }

                treemap.verify(TestNode.cmp);
                try std.testing.expectEqual(hashmap.size, treemap.size);
            }

            try std.testing.expectEqual(hashmap.count(), treemap.size);
        }
    }.testOne, .{});
}
