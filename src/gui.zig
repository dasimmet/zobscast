/// GUI indicator for Zobscast active state in OBS Studio.
///
/// Features:
/// 1. Checkable Tools menu item: shows a checkmark (✓) next to "Toggle Zobscast"
///    when streaming is active, and removes it when stopped.
/// 2. OBS status bar indicator displaying cast state.
/// 3. Native Qt WebEngine settings window styled like OBS Studio dark theme,
///    with fallback to QDesktopServices::openUrl / system browser.
const std = @import("std");
const c = @import("c");
const builtin = @import("builtin");

const QList = extern struct {
    d: ?*anyopaque,
    ptr: [*]?*anyopaque,
    size: isize,
};

const QByteArrayView = extern struct {
    size: isize,
    data: [*c]const u8,
};

const QString = extern struct {
    d: ?*anyopaque = null,
    ptr: ?*anyopaque = null,
    size: isize = 0,
};

const QUrl = extern struct {
    d: ?*anyopaque = null,
};

const ActionsFn = *const fn (*QList, ?*anyopaque) callconv(.c) void;
const MenuObjectFn = *const fn (?*anyopaque) callconv(.c) ?*anyopaque;
const BoolFn = *const fn (?*anyopaque, bool) callconv(.c) void;
const MenuBarFn = *const fn (?*anyopaque) callconv(.c) ?*anyopaque;
const StatusBarFn = *const fn (?*anyopaque) callconv(.c) ?*anyopaque;
const StatusShowFn = *const fn (?*anyopaque, ?*const anyopaque, c_int) callconv(.c) void;

const QSize = extern struct {
    width: c_int,
    height: c_int,
};

// QWidget functions
const WidgetResizeFn = *const fn (?*anyopaque, c_int, c_int) callconv(.c) void;
const WidgetResizeSizeFn = *const fn (?*anyopaque, *const QSize) callconv(.c) void;
const WidgetSetTitleFn = *const fn (?*anyopaque, ?*const anyopaque) callconv(.c) void;
const WidgetSetAttrFn = *const fn (?*anyopaque, c_int, bool) callconv(.c) void;
const WidgetVoidFn = *const fn (?*anyopaque) callconv(.c) void;

// QWebEngineView functions
const WebEngineViewCtorFn = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;
const WebEngineViewLoadFn = *const fn (?*anyopaque, ?*const anyopaque) callconv(.c) void;

// QString / QUrl / QArrayData functions
const QStringFromUtf8Fn = *const fn (*QString, QByteArrayView) callconv(.c) void;
const QUrlFromEncodedFn = *const fn (*QUrl, QByteArrayView, c_int) callconv(.c) void;
const QUrlDtorFn = *const fn (*QUrl) callconv(.c) void;
const QDesktopOpenUrlFn = *const fn (?*const anyopaque) callconv(.c) bool;
const OperatorNewFn = *const fn (usize) callconv(.c) ?*anyopaque;

var fn_set_checkable: ?BoolFn = null;
var fn_set_checked: ?BoolFn = null;
var fn_menu_bar: ?MenuBarFn = null;
var fn_actions: ?ActionsFn = null;
var fn_menu_object: ?MenuObjectFn = null;
var fn_status_bar: ?StatusBarFn = null;
var fn_status_show: ?StatusShowFn = null;

var fn_widget_resize: ?WidgetResizeFn = null;
var fn_widget_resize_size: ?WidgetResizeSizeFn = null;
var fn_widget_set_title: ?WidgetSetTitleFn = null;
var fn_widget_set_attr: ?WidgetSetAttrFn = null;
var fn_widget_show: ?WidgetVoidFn = null;
var fn_widget_raise: ?WidgetVoidFn = null;
var fn_widget_activate: ?WidgetVoidFn = null;

var fn_web_ctor: ?WebEngineViewCtorFn = null;
var fn_web_load: ?WebEngineViewLoadFn = null;

var fn_qstring_from_utf8: ?QStringFromUtf8Fn = null;
var fn_qurl_from_encoded: ?QUrlFromEncodedFn = null;
var fn_qurl_dtor: ?QUrlDtorFn = null;
var fn_desktop_open_url: ?QDesktopOpenUrlFn = null;
var fn_operator_new: ?OperatorNewFn = null;

var cached_action: ?*anyopaque = null;
var qt_loaded: bool = false;

const RTLD_LAZY: c_int = 1;
const RTLD_NOLOAD: c_int = 4;
extern fn dlopen(path: [*c]const u8, flags: c_int) ?*anyopaque;
extern fn dlsym(handle: ?*anyopaque, sym: [*c]const u8) ?*anyopaque;

fn loadLibrary(name: [*c]const u8) ?*anyopaque {
    if (comptime builtin.os.tag == .windows) {
        if (c.GetModuleHandleA(name)) |h| return @ptrCast(h);
        if (c.LoadLibraryA(name)) |h| return @ptrCast(h);
        return null;
    } else {
        var h = dlopen(name, RTLD_LAZY | RTLD_NOLOAD);
        if (h == null) h = dlopen(name, RTLD_LAZY);
        return h;
    }
}

fn loadSymbol(handle: ?*anyopaque, sym: [*c]const u8) ?*anyopaque {
    if (handle == null) return null;
    if (comptime builtin.os.tag == .windows) {
        if (c.GetProcAddress(@ptrCast(@alignCast(handle)), sym)) |p| return @ptrCast(@constCast(p));
        return null;
    } else {
        return dlsym(handle, sym);
    }
}

fn loadQt() void {
    if (qt_loaded) return;
    qt_loaded = true;

    const core_lib: [*c]const u8 = switch (builtin.os.tag) {
        .windows => "Qt6Core.dll",
        .macos => "libQt6Core.dylib",
        else => "libQt6Core.so.6",
    };
    const gui_lib: [*c]const u8 = switch (builtin.os.tag) {
        .windows => "Qt6Gui.dll",
        .macos => "libQt6Gui.dylib",
        else => "libQt6Gui.so.6",
    };
    const widgets_lib: [*c]const u8 = switch (builtin.os.tag) {
        .windows => "Qt6Widgets.dll",
        .macos => "libQt6Widgets.dylib",
        else => "libQt6Widgets.so.6",
    };
    const web_lib: [*c]const u8 = switch (builtin.os.tag) {
        .windows => "Qt6WebEngineWidgets.dll",
        .macos => "libQt6WebEngineWidgets.dylib",
        else => "libQt6WebEngineWidgets.so.6",
    };
    const cpp_lib: ?[*c]const u8 = switch (builtin.os.tag) {
        .windows => "msvcrt.dll",
        .macos => "libc++.dylib",
        .linux => "libstdc++.so.6",
        else => null,
    };

    const h_core = loadLibrary(core_lib);
    const h_gui = loadLibrary(gui_lib);
    const h_widgets = loadLibrary(widgets_lib);
    const h_web = loadLibrary(web_lib);
    const h_cpp = if (cpp_lib) |cl| loadLibrary(cl) else null;

    if (h_core) |hc| {
        if (loadSymbol(hc, "_ZN7QString8fromUtf8E14QByteArrayView")) |sym| {
            fn_qstring_from_utf8 = @ptrCast(@alignCast(sym));
        }
        if (loadSymbol(hc, "_ZN4QUrl11fromEncodedE14QByteArrayViewNS_11ParsingModeE")) |sym| {
            fn_qurl_from_encoded = @ptrCast(@alignCast(sym));
        }
        if (loadSymbol(hc, "_ZN4QUrlD1Ev")) |sym| {
            fn_qurl_dtor = @ptrCast(@alignCast(sym));
        }
    }

    if (h_gui) |hg| {
        if (loadSymbol(hg, "_ZN7QAction12setCheckableEb")) |sym| {
            fn_set_checkable = @ptrCast(@alignCast(sym));
        }
        if (loadSymbol(hg, "_ZN7QAction10setCheckedEb")) |sym| {
            fn_set_checked = @ptrCast(@alignCast(sym));
        }
        if (loadSymbol(hg, "_ZNK7QAction10menuObjectEv")) |sym| {
            fn_menu_object = @ptrCast(@alignCast(sym));
        }
        if (loadSymbol(hg, "_ZN16QDesktopServices7openUrlERK4QUrl")) |sym| {
            fn_desktop_open_url = @ptrCast(@alignCast(sym));
        }
    }

    if (h_widgets) |hw| {
        c.blog(c.LOG_INFO, "zobscast GUI: Qt6Widgets loaded");
        if (loadSymbol(hw, "_ZNK11QMainWindow7menuBarEv")) |sym| {
            fn_menu_bar = @ptrCast(@alignCast(sym));
        }
        if (loadSymbol(hw, "_ZNK7QWidget7actionsEv")) |sym| {
            fn_actions = @ptrCast(@alignCast(sym));
        }
        if (loadSymbol(hw, "_ZNK11QMainWindow9statusBarEv")) |sym| {
            fn_status_bar = @ptrCast(@alignCast(sym));
        }
        if (loadSymbol(hw, "_ZN10QStatusBar11showMessageERK7QStringi")) |sym| {
            fn_status_show = @ptrCast(@alignCast(sym));
        }
        if (loadSymbol(hw, "_ZN7QWidget6resizeERK5QSize")) |sym| {
            fn_widget_resize_size = @ptrCast(@alignCast(sym));
        } else if (loadSymbol(hw, "?resize@QWidget@@QEAAXAEBVQSize@@@Z")) |sym| {
            fn_widget_resize_size = @ptrCast(@alignCast(sym));
        }
        if (loadSymbol(hw, "_ZN7QWidget6resizeEii")) |sym| {
            fn_widget_resize = @ptrCast(@alignCast(sym));
        } else if (loadSymbol(hw, "?resize@QWidget@@QEAAXHH@Z")) |sym| {
            fn_widget_resize = @ptrCast(@alignCast(sym));
        }
        if (loadSymbol(hw, "_ZN7QWidget14setWindowTitleERK7QString")) |sym| {
            fn_widget_set_title = @ptrCast(@alignCast(sym));
        }
        if (loadSymbol(hw, "_ZN7QWidget12setAttributeEN2Qt15WidgetAttributeEb")) |sym| {
            fn_widget_set_attr = @ptrCast(@alignCast(sym));
        }
        if (loadSymbol(hw, "_ZN7QWidget4showEv")) |sym| {
            fn_widget_show = @ptrCast(@alignCast(sym));
        }
        if (loadSymbol(hw, "_ZN7QWidget5raiseEv")) |sym| {
            fn_widget_raise = @ptrCast(@alignCast(sym));
        }
        if (loadSymbol(hw, "_ZN7QWidget14activateWindowEv")) |sym| {
            fn_widget_activate = @ptrCast(@alignCast(sym));
        }
    }

    if (h_web) |hweb| {
        c.blog(c.LOG_INFO, "zobscast GUI: Qt6WebEngineWidgets loaded");
        if (loadSymbol(hweb, "_ZN14QWebEngineViewC1EP7QWidget")) |sym| {
            fn_web_ctor = @ptrCast(@alignCast(sym));
        }
        if (loadSymbol(hweb, "_ZN14QWebEngineView4loadERK4QUrl")) |sym| {
            fn_web_load = @ptrCast(@alignCast(sym));
        }
    }

    if (h_cpp) |hcpp| {
        if (loadSymbol(hcpp, "_Znwm")) |sym| {
            fn_operator_new = @ptrCast(@alignCast(sym));
        } else if (loadSymbol(hcpp, "??2@YAPEAX_K@Z")) |sym| {
            fn_operator_new = @ptrCast(@alignCast(sym));
        }
    }

    if (fn_set_checkable != null and fn_set_checked != null) {
        c.blog(c.LOG_INFO, "zobscast GUI: Qt6 action checkmark support loaded");
    }
    if (fn_status_bar != null and fn_status_show != null) {
        c.blog(c.LOG_INFO, "zobscast GUI: Qt6 status bar support loaded");
    }
    if (fn_web_ctor != null and fn_web_load != null) {
        c.blog(c.LOG_INFO, "zobscast GUI: Qt6 WebEngineView support loaded");
    } else {
        c.blog(c.LOG_INFO, "zobscast GUI: Qt6 WebEngineView not found, will use desktop browser fallback");
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

/// Updates the checkmark state and OBS status bar message.
pub fn setActive(active: bool) void {
    if (cached_action == null) {
        findToolsAction();
    }
    if (cached_action) |act| {
        if (fn_set_checked) |f| {
            f(act, active);
        }
    }

    updateStatusBar(active);
}

fn updateStatusBar(active: bool) void {
    const main_win = c.obs_frontend_get_main_window();
    if (main_win == null) return;

    const get_sb = fn_status_bar orelse return;
    const show_msg = fn_status_show orelse return;
    const from_utf8 = fn_qstring_from_utf8 orelse return;

    const sb = get_sb(main_win) orelse return;

    const msg_text = if (active) "Zobscast: Casting Active" else "Zobscast: Inactive";
    var qs: QString = .{};
    from_utf8(&qs, .{ .size = @intCast(msg_text.len), .data = msg_text.ptr });
    show_msg(sb, &qs, if (active) 0 else 4000);
}

/// Opens the settings URL inside a native Qt WebEngine window if available,
/// or falls back to the system/desktop web browser.
pub fn openSettings(url: [:0]const u8) void {
    c.blog(c.LOG_INFO, "zobscast GUI: openSettings called for %s", url.ptr);
    loadQt();

    if (openQtWebEngine(url)) {
        c.blog(c.LOG_INFO, "zobscast GUI: opened native Qt WebEngine settings view");
        return;
    }

    c.blog(c.LOG_INFO, "zobscast GUI: falling back to external browser");
    openExternalBrowser(url);
}

fn openQtWebEngine(url: [:0]const u8) bool {
    const ctor = fn_web_ctor orelse {
        c.blog(c.LOG_INFO, "zobscast GUI: fn_web_ctor is null");
        return false;
    };
    const load_fn = fn_web_load orelse {
        c.blog(c.LOG_INFO, "zobscast GUI: fn_web_load is null");
        return false;
    };
    const show_fn = fn_widget_show orelse {
        c.blog(c.LOG_INFO, "zobscast GUI: fn_widget_show is null");
        return false;
    };
    const qurl_from_encoded = fn_qurl_from_encoded orelse {
        c.blog(c.LOG_INFO, "zobscast GUI: fn_qurl_from_encoded is null");
        return false;
    };
    const qurl_dtor = fn_qurl_dtor orelse {
        c.blog(c.LOG_INFO, "zobscast GUI: fn_qurl_dtor is null");
        return false;
    };

    // Allocate memory for QWebEngineView (256 bytes comfortably accommodates the widget structure)
    const mem = if (fn_operator_new) |new_fn|
        new_fn(256)
    else
        malloc(256);

    if (mem == null) return false;

    // Construct QWebEngineView(parent = nullptr)
    ctor(mem, null);

    // Set WA_DeleteOnClose (attribute 55 in Qt)
    if (fn_widget_set_attr) |set_attr| {
        set_attr(mem, 55, true);
    }

    // Set window title "Zobscast Settings"
    if (fn_widget_set_title) |set_title| {
        if (fn_qstring_from_utf8) |from_utf8| {
            const title = "Zobscast Settings";
            var qs: QString = .{};
            from_utf8(&qs, .{ .size = @intCast(title.len), .data = title.ptr });
            set_title(mem, &qs);
        }
    }

    // Resize window (optional — works even without resize support)
    if (fn_widget_resize_size) |resize_size| {
        const sz: QSize = .{ .width = 500, .height = 620 };
        resize_size(mem, &sz);
    } else if (fn_widget_resize) |resize_fn| {
        resize_fn(mem, 500, 620);
    }

    // Load URL
    var qurl: QUrl = .{};
    qurl_from_encoded(&qurl, .{ .size = @intCast(url.len), .data = url.ptr }, 0);
    load_fn(mem, &qurl);
    qurl_dtor(&qurl);

    // Show and bring to front
    show_fn(mem);
    if (fn_widget_raise) |raise_fn| raise_fn(mem);
    if (fn_widget_activate) |act_fn| act_fn(mem);

    return true;
}

extern fn malloc(usize) ?*anyopaque;
extern fn system([*c]const u8) c_int;

fn openExternalBrowser(url: [:0]const u8) void {
    // 1. Try QDesktopServices::openUrl
    if (fn_desktop_open_url) |open_url| {
        if (fn_qurl_from_encoded) |qurl_from_encoded| {
            if (fn_qurl_dtor) |qurl_dtor| {
                var qurl: QUrl = .{};
                qurl_from_encoded(&qurl, .{ .size = @intCast(url.len), .data = url.ptr }, 0);
                const res = open_url(&qurl);
                qurl_dtor(&qurl);
                if (res) {
                    c.blog(c.LOG_INFO, "zobscast GUI: opened settings via QDesktopServices");
                    return;
                }
            }
        }
    }

    // 2. OS process launcher fallback
    c.blog(c.LOG_INFO, "zobscast GUI: launching settings in OS default browser: %s", url.ptr);
    var cmd_buf: [512:0]u8 = undefined;
    if (comptime builtin.os.tag == .windows) {
        if (std.mem.printSentinel(&cmd_buf, "cmd.exe /c start \"\" \"{s}\"", .{url}, 0)) |cmd| {
            _ = system(cmd.ptr);
        } else |_| {}
    } else if (comptime builtin.os.tag.isDarwin()) {
        if (std.mem.printSentinel(&cmd_buf, "open '{s}' &", .{url}, 0)) |cmd| {
            _ = system(cmd.ptr);
        } else |_| {}
    } else {
        if (std.mem.printSentinel(&cmd_buf, "xdg-open '{s}' &", .{url}, 0)) |cmd| {
            _ = system(cmd.ptr);
        } else |_| {}
    }
}
