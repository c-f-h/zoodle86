/// Application context structure
pub const AppContext = extern struct {
    name: [*:0]const u8,
    key_event_handler: ?*const fn (?*const anyopaque) callconv(.c) u32,
};
