//! Tiny Rust process entry point for exercising Elisa's emitted object without
//! relying on the stage1 compiler's host executable-link fallback.

use std::ffi::c_void;

#[link(name = "elisapkg_tuf_ffi_spike", kind = "static")]
unsafe extern "C" {
    fn elisapkg_tuf_engine_abi_version_v1() -> u32;
}

unsafe extern "C" {
    fn elisapkg_tuf_probe_run_v1() -> i64;
}

// Test-only equivalents of the compiler's weak callback fallback. These are
// Rust ABI definitions so the FFI proof does not add C source files.
#[no_mangle]
extern "C" fn elisa_native_callback_ptr(_name: *mut u8) -> *mut c_void {
    std::ptr::null_mut()
}

#[no_mangle]
extern "C" fn elisa_native_callback_call_u32_voidp(
    _name: *mut u8,
    _arg: *mut c_void,
    fallback: u32,
) -> u32 {
    fallback
}

#[no_mangle]
extern "C" fn elisa_native_callback_call_i32_voidp(
    _name: *mut u8,
    _arg: *mut c_void,
    fallback: i32,
) -> i32 {
    fallback
}

#[no_mangle]
extern "C" fn elisa_native_callback_call_usize_voidp(
    _name: *mut u8,
    _arg: *mut c_void,
    fallback: usize,
) -> usize {
    fallback
}

#[no_mangle]
extern "C" fn elisa_native_callback_call_isize_voidp(
    _name: *mut u8,
    _arg: *mut c_void,
    fallback: isize,
) -> isize {
    fallback
}

#[no_mangle]
extern "C" fn elisa_native_callback_spawn_join_u32_voidp(
    _name: *mut u8,
    _arg: *mut c_void,
    fallback: u32,
) -> u32 {
    fallback
}

#[no_mangle]
extern "C" fn elisa_native_callback_context_new_u32_voidp(
    _name: *mut u8,
    _arg: *mut c_void,
    _fallback: u32,
) -> *mut c_void {
    std::ptr::null_mut()
}

#[no_mangle]
extern "C" fn elisa_native_callback_context_entry_u32_voidp() -> *mut c_void {
    std::ptr::null_mut()
}

#[no_mangle]
extern "C" fn elisa_native_callback_context_start_u32_voidp(
    _ctx: *mut c_void,
    _thread: *mut usize,
) -> i32 {
    -1
}

#[no_mangle]
extern "C" fn elisa_native_callback_context_join_u32_voidp(
    _handle: usize,
    _ctx: *mut c_void,
    fallback: u32,
) -> u32 {
    fallback
}

#[no_mangle]
extern "C" fn elisa_native_callback_context_spawn_join_u32_voidp(
    _ctx: *mut c_void,
    fallback: u32,
) -> u32 {
    fallback
}

#[no_mangle]
extern "C" fn elisa_native_callback_context_result_u32(_ctx: *mut c_void, fallback: u32) -> u32 {
    fallback
}

#[no_mangle]
extern "C" fn elisa_native_callback_context_free(_ctx: *mut c_void) {}

#[no_mangle]
extern "C" fn va_copy(source: *mut c_void) -> *mut c_void {
    source
}

#[no_mangle]
extern "C" fn va_end(_argument: *mut c_void) {}

fn main() {
    // SAFETY: both symbols are linked from the pinned static library and the
    // Elisa object emitted by the paired spike build.
    let version = unsafe { elisapkg_tuf_engine_abi_version_v1() };
    if version != 1 {
        std::process::exit(90);
    }
    let result = unsafe { elisapkg_tuf_probe_run_v1() };
    std::process::exit(result as i32);
}
