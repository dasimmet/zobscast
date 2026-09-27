/// GUI indicator for Zobscast active state in OBS Studio.
///
/// Features:
/// 1. Checkable Tools menu item: shows a checkmark (✓) next to "Toggle Zobscast"
///    when streaming is active, and removes it when stopped.
/// 2. Dynamic status text in "Zobscast Options" properties dialog.
const std = @import("std");
const c = @import("c");

const QList = extern struct {
    d: ?*anyopaque,
    ptr: [*]?*anyopaque,
    size: isize,
};

const ActionsFn = *const fn (*QList, ?*anyopaque) callconv(.c) void;
const MenuObjectFn = *const fn (?*anyopaque) callconv(.c) ?*anyopaque;
const BoolFn = *const fn (?*anyopaque, bool) callconv(.c) void;
const MenuBarFn = *const fn (?*anyopaque) callconv(.c) ?*anyopaque;

var fn_set_checkable: ?BoolFn = null;
var fn_set_checked: ?BoolFn = null;
var fn_menu_bar: ?MenuBarFn = null;
var fn_actions: ?ActionsFn = null;
var fn_menu_object: ?MenuObjectFn = null;

var cached_action: ?*anyopaque = null;
var qt_loaded: bool = false;

const RTLD_LAZY: c_int = 1;
const RTLD_NOLOAD: c_int = 4;
extern fn dlopen(path: [*c]const u8, flags: c_int) ?*anyopaque;
extern fn dlsym(handle: ?*anyopaque, sym: [*c]const u8) ?*anyopaque;

fn loadQt() void {
    if (qt_loaded) return;
    qt_loaded = true;

    // Load Qt6Gui, Qt6Widgets
    var h_gui = dlopen("libQt6Gui.so.6", RTLD_LAZY | RTLD_NOLOAD);
    if (h_gui == null) h_gui = dlopen("libQt6Gui.so.6", RTLD_LAZY);

    var h_widgets = dlopen("libQt6Widgets.so.6", RTLD_LAZY | RTLD_NOLOAD);
    if (h_widgets == null) h_widgets = dlopen("libQt6Widgets.so.6", RTLD_LAZY);

    if (h_gui) |hg| {
        if (dlsym(hg, "_ZN7QAction12setCheckableEb")) |sym| {
            fn_set_checkable = @ptrCast(sym);
        }
        if (dlsym(hg, "_ZN7QAction10setCheckedEb")) |sym| {
            fn_set_checked = @ptrCast(sym);
        }
        if (dlsym(hg, "_ZNK7QAction10menuObjectEv")) |sym| {
            fn_menu_object = @ptrCast(sym);
        }
    }

    if (h_widgets) |hw| {
        if (dlsym(hw, "_ZNK11QMainWindow7menuBarEv")) |sym| {
            fn_menu_bar = @ptrCast(sym);
        }
        if (dlsym(hw, "_ZNK7QWidget7actionsEv")) |sym| {
            fn_actions = @ptrCast(sym);
        }
    }

    if (fn_set_checkable != null and fn_set_checked != null) {
        c.blog(c.LOG_INFO, "zobscast GUI: Qt6 action checkmark support loaded");
    } else {
        c.blog(c.LOG_WARNING, "zobscast GUI: Qt6 symbols not found, checkmark indicator disabled");
    }
}

/// Register the menu item via OBS frontend and find its QAction to make it checkable.
pub fn addToggleAction(name: [*c]const u8, callback: c.obs_frontend_cb, ctx: ?*anyopaque) void {
    loadQt();

    // 1. Add menu item via OBS frontend API (registers click handler)
    c.obs_frontend_add_tools_menu_item(name, callback, ctx);

    // 2. Discover the QAction that was just added to the Tools menu
    findToolsAction();

    // 3. Make it checkable so the checkmark is visible
    if (cached_action) |act| {
        if (fn_set_checkable) |sc| {
            sc(act, true);
            c.blog(c.LOG_INFO, "zobscast GUI: menu item made checkable");
        }
    }
}

fn findToolsAction() void {
    if (cached_action != null) return;
    const main_win = c.obs_frontend_get_main_window();
    if (main_win == null) return;

    const get_menu_bar = fn_menu_bar orelse return;
    const get_actions = fn_actions orelse return;
    const get_menu_obj = fn_menu_object orelse return;

    const menu_bar = get_menu_bar(main_win) orelse return;

    var bar_list: QList = undefined;
    get_actions(&bar_list, menu_bar);
    if (bar_list.size <= 0) return;

    // Scan top-level menus for "Tools" menu
    var i: isize = 0;
    while (i < bar_list.size) : (i += 1) {
        const top_action = bar_list.ptr[@intCast(i)];
        if (top_action == null) continue;

        const sub_menu = get_menu_obj(top_action);
        if (sub_menu == null) continue;

        var sub_list: QList = undefined;
        get_actions(&sub_list, sub_menu);
        if (sub_list.size <= 0) continue;

        // In the Tools menu, our newly added action is typically the last item
        var j: isize = sub_list.size - 1;
        while (j >= 0) : (j -= 1) {
            if (sub_list.ptr[@intCast(j)]) |candidate| {
                cached_action = candidate;
                return;
            }
        }
    }
}

/// Updates the checkmark state (checked = active casting, unchecked = idle).
pub fn setActive(active: bool) void {
    if (cached_action == null) {
        findToolsAction();
    }
    if (cached_action) |act| {
        if (fn_set_checked) |f| {
            f(act, active);
        }
    }
}
