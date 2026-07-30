const std = @import("std");
const wl = @import("wayland.zig");
const linux = std.os.linux;

pub fn main(init: std.process.Init) !void {
    const fd = try wl.display_connect(init.environ_map);
    defer _ = linux.close(fd);

    var client = wl.WaylandClient{
        .fd = fd,
    };

    client.wl_registry = try wl.wl_display_get_registry(&client);
    client.sync_id     = try wl.wl_display_sync(&client);

    try wl.read_event_message(&client);

    // we can bind to wl_output using wl_registry_bind.
    // Now that we have wl_output object we can call
    // zwlr_gamma_control_manager_v1::get_gamma_control::get_gamma_control(
    //      id: new_id<zwlr_gamma_control_v1>, output: object<wl_output>
    // )
    //
    // and we are going to use it to call
    // zwlr_gamma_control_v1::set_gamma(fd: fd) 
    //
    // here im not sure what i should do, the docs say
    // "The file descriptor can be memory-mapped to provide the raw gamma 
    // table, which contains successive gamma ramps for the red, green 
    // and blue channels."
    //
    // i notice the "can", so should i? why? can't i just write into the 
    // unix socket we have already been using? 
    // Im guessing that we should use a memory shared mapped fd to avoid
    // syscalls, but in case of a blue light filter utility, is this
    // really needed?
}


