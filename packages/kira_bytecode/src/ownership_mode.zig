pub const OwnershipMode = enum(u8) {
    owned,
    borrow_read,
    borrow_mut,
    move,
    copy,
};
