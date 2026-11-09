//! Test-only C ABI proof for the pinned, transport-free TUF verifier.
//!
//! Elisa must validate the bounded metadata JSON and reject duplicate object
//! keys before calling this interface. This crate does not own persistent
//! trust state, filesystem paths, network transport, or package policy.

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::slice;

use serde_json::Value;
use sigstore_tuf::{Root, TrustedMetadataSet};

const ABI_VERSION: u32 = 1;
const MAX_ROOT_BYTES: usize = 1_048_576;

const STATUS_OK: i32 = 0;
const STATUS_INVALID_ARGUMENT: i32 = 1;
const STATUS_INVALID_ROOT: i32 = 2;
const STATUS_UNSUPPORTED_SPEC: i32 = 3;
const STATUS_INTERNAL_PANIC: i32 = 4;

#[derive(Debug, Clone, Copy)]
struct VerifiedRootSummary {
    version: u64,
    key_count: u32,
    root_threshold: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum VerifyError {
    InvalidRoot,
    UnsupportedSpec,
}

/// Return the ABI version expected by the private Elisa adapter.
#[no_mangle]
pub extern "C" fn elisapkg_tuf_engine_abi_version_v1() -> u32 {
    ABI_VERSION
}

/// Verify the self-signature threshold of a bounded bootstrap root.
///
/// The caller must provide a readable input range and writable output
/// locations for the duration of this call. Elisa owns those buffers. Every
/// output remains untouched unless root verification succeeds. This function
/// catches Rust unwinding panics so none cross the C ABI; invalid pointers
/// remain a caller contract violation, as they do for ordinary C functions.
///
/// Status values are stable within ABI v1: 0 success, 1 invalid argument,
/// 2 malformed or cryptographically invalid root, 3 unsupported profile
/// version, and 4 contained Rust panic.
///
/// # Safety
///
/// `metadata` must point to `metadata_len` readable bytes. Each output pointer
/// must be aligned and writable for its pointee type, and the three output
/// ranges must not overlap. The input bytes must have passed Elisa's bounded
/// duplicate-key and canonical-number precheck before this function is called.
#[no_mangle]
pub unsafe extern "C" fn elisapkg_tuf_engine_verify_root_v1(
    metadata: *const u8,
    metadata_len: usize,
    out_version: *mut u64,
    out_key_count: *mut u32,
    out_root_threshold: *mut u32,
) -> i32 {
    if metadata.is_null()
        || metadata_len == 0
        || metadata_len > MAX_ROOT_BYTES
        || out_version.is_null()
        || out_key_count.is_null()
        || out_root_threshold.is_null()
    {
        return STATUS_INVALID_ARGUMENT;
    }

    let verification = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: null and length bounds are checked above. The caller contract
        // requires `metadata` to address `metadata_len` readable bytes.
        let bytes = unsafe { slice::from_raw_parts(metadata, metadata_len) };
        verify_root_bytes(bytes)
    }));

    let summary = match verification {
        Ok(Ok(summary)) => summary,
        Ok(Err(VerifyError::UnsupportedSpec)) => return STATUS_UNSUPPORTED_SPEC,
        Ok(Err(VerifyError::InvalidRoot)) => return STATUS_INVALID_ROOT,
        Err(_) => return STATUS_INTERNAL_PANIC,
    };

    // SAFETY: non-null output locations were checked above. Their writable
    // extent and exclusive access are part of the caller contract.
    unsafe {
        *out_version = summary.version;
        *out_key_count = summary.key_count;
        *out_root_threshold = summary.root_threshold;
    }
    STATUS_OK
}

/// Verify exactly one sequential root-rotation link without persisting state.
///
/// The caller supplies its current trusted root and one candidate root. On
/// success, the caller must durably persist the candidate bytes before asking
/// this function to validate the next root. This operation intentionally does
/// no filesystem or network I/O and does not check final-root expiry.
///
/// Status values match [`elisapkg_tuf_engine_verify_root_v1`].
///
/// # Safety
///
/// Both input pointers must address their respective readable byte ranges.
/// Each output pointer must be aligned and writable for its pointee type; the
/// outputs must not overlap each other or either input range. The trusted and
/// candidate bytes must both have passed Elisa's bounded duplicate-key and
/// canonical-number precheck.
#[no_mangle]
pub unsafe extern "C" fn elisapkg_tuf_engine_verify_root_update_v1(
    trusted_root: *const u8,
    trusted_root_len: usize,
    candidate_root: *const u8,
    candidate_root_len: usize,
    out_version: *mut u64,
    out_key_count: *mut u32,
    out_root_threshold: *mut u32,
) -> i32 {
    if trusted_root.is_null()
        || trusted_root_len == 0
        || trusted_root_len > MAX_ROOT_BYTES
        || candidate_root.is_null()
        || candidate_root_len == 0
        || candidate_root_len > MAX_ROOT_BYTES
        || out_version.is_null()
        || out_key_count.is_null()
        || out_root_threshold.is_null()
    {
        return STATUS_INVALID_ARGUMENT;
    }

    let verification = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: null and length bounds are checked above. The caller contract
        // requires both pointers to address their respective readable ranges.
        let trusted_bytes = unsafe { slice::from_raw_parts(trusted_root, trusted_root_len) };
        let candidate_bytes = unsafe { slice::from_raw_parts(candidate_root, candidate_root_len) };
        verify_root_update_bytes(trusted_bytes, candidate_bytes)
    }));

    let summary = match verification {
        Ok(Ok(summary)) => summary,
        Ok(Err(VerifyError::UnsupportedSpec)) => return STATUS_UNSUPPORTED_SPEC,
        Ok(Err(VerifyError::InvalidRoot)) => return STATUS_INVALID_ROOT,
        Err(_) => return STATUS_INTERNAL_PANIC,
    };

    // SAFETY: non-null output locations were checked above. Their writable,
    // non-overlapping extent is part of the caller contract.
    unsafe {
        *out_version = summary.version;
        *out_key_count = summary.key_count;
        *out_root_threshold = summary.root_threshold;
    }
    STATUS_OK
}

fn verify_root_bytes(bytes: &[u8]) -> Result<VerifiedRootSummary, VerifyError> {
    validate_root_spec_version(bytes)?;

    let trusted = TrustedMetadataSet::from_root(bytes).map_err(|_| VerifyError::InvalidRoot)?;
    summarize_root(trusted.root())
}

fn verify_root_update_bytes(
    trusted_bytes: &[u8],
    candidate_bytes: &[u8],
) -> Result<VerifiedRootSummary, VerifyError> {
    validate_root_spec_version(trusted_bytes)?;
    validate_root_spec_version(candidate_bytes)?;

    let mut trusted =
        TrustedMetadataSet::from_root(trusted_bytes).map_err(|_| VerifyError::InvalidRoot)?;
    trusted
        .update_root(candidate_bytes)
        .map_err(|_| VerifyError::InvalidRoot)?;
    summarize_root(trusted.root())
}

fn validate_root_spec_version(bytes: &[u8]) -> Result<(), VerifyError> {
    // Elisa's bounded precheck is authoritative for duplicate-key rejection
    // and canonical integer syntax. Parsing here extracts only the profile
    // field before delegating signature and schema validation to sigstore-tuf.
    let value: Value = serde_json::from_slice(bytes).map_err(|_| VerifyError::InvalidRoot)?;
    let spec_version = value
        .get("signed")
        .and_then(|signed| signed.get("spec_version"))
        .and_then(Value::as_str)
        .ok_or(VerifyError::InvalidRoot)?;
    if !supported_spec_version(spec_version) {
        return Err(VerifyError::UnsupportedSpec);
    }
    Ok(())
}

fn summarize_root(root: &Root) -> Result<VerifiedRootSummary, VerifyError> {
    let root_role = root.role("root").ok_or(VerifyError::InvalidRoot)?;
    let key_count = u32::try_from(root.keys.len()).map_err(|_| VerifyError::InvalidRoot)?;
    let root_threshold =
        u32::try_from(root_role.threshold).map_err(|_| VerifyError::InvalidRoot)?;

    Ok(VerifiedRootSummary {
        version: root.version,
        key_count,
        root_threshold,
    })
}

fn supported_spec_version(version: &str) -> bool {
    let Some(patch) = version.strip_prefix("1.0.") else {
        return false;
    };
    if patch.is_empty() || patch.len() > 2 || (patch.len() == 2 && patch.starts_with('0')) {
        return false;
    }
    patch
        .parse::<u8>()
        .map(|patch| patch <= 36)
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn profile_version_is_the_pinned_stable_range() {
        for accepted in ["1.0.0", "1.0.9", "1.0.36"] {
            assert!(supported_spec_version(accepted), "{accepted}");
        }
        for rejected in [
            "1.0.00",
            "1.0.37",
            "1.0.1-alpha",
            "1.0.1+build",
            "1.1.0",
            "2.0.0",
            "x.0.1",
        ] {
            assert!(!supported_spec_version(rejected), "{rejected}");
        }
    }

    #[test]
    fn abi_rejects_unbounded_or_missing_buffers_without_writing_outputs() {
        assert_eq!(elisapkg_tuf_engine_abi_version_v1(), ABI_VERSION);

        let mut version = 0xfeed_u64;
        let mut key_count = 0xfeed_u32;
        let mut threshold = 0xfeed_u32;
        let result = unsafe {
            elisapkg_tuf_engine_verify_root_v1(
                std::ptr::null(),
                1,
                &mut version,
                &mut key_count,
                &mut threshold,
            )
        };
        assert_eq!(result, STATUS_INVALID_ARGUMENT);
        assert_eq!(version, 0xfeed_u64);
        assert_eq!(key_count, 0xfeed_u32);
        assert_eq!(threshold, 0xfeed_u32);

        let byte = b"{}";
        let result = unsafe {
            elisapkg_tuf_engine_verify_root_v1(
                byte.as_ptr(),
                MAX_ROOT_BYTES + 1,
                &mut version,
                &mut key_count,
                &mut threshold,
            )
        };
        assert_eq!(result, STATUS_INVALID_ARGUMENT);
        assert_eq!(version, 0xfeed_u64);
        assert_eq!(key_count, 0xfeed_u32);
        assert_eq!(threshold, 0xfeed_u32);
    }

    #[test]
    fn invalid_root_does_not_publish_partial_summary() {
        let bytes = br#"{"signed":{},"signatures":[]}"#;
        let mut version = 0xfeed_u64;
        let mut key_count = 0xfeed_u32;
        let mut threshold = 0xfeed_u32;
        let result = unsafe {
            elisapkg_tuf_engine_verify_root_v1(
                bytes.as_ptr(),
                bytes.len(),
                &mut version,
                &mut key_count,
                &mut threshold,
            )
        };
        assert_eq!(result, STATUS_INVALID_ROOT);
        assert_eq!(version, 0xfeed_u64);
        assert_eq!(key_count, 0xfeed_u32);
        assert_eq!(threshold, 0xfeed_u32);
    }

    #[test]
    fn verifies_and_publishes_a_real_signed_root_summary() {
        let bytes = include_bytes!("../testdata/github-root.json");
        let value: Value = serde_json::from_slice(bytes).expect("fixture JSON");
        let signed = &value["signed"];
        let expected_version = signed["version"].as_u64().expect("root version");
        let expected_keys = u32::try_from(signed["keys"].as_object().expect("root keys").len())
            .expect("fixture key count fits u32");
        let expected_threshold = u32::try_from(
            signed["roles"]["root"]["threshold"]
                .as_u64()
                .expect("root threshold"),
        )
        .expect("fixture threshold fits u32");
        let mut version = 0;
        let mut key_count = 0;
        let mut threshold = 0;

        let result = unsafe {
            elisapkg_tuf_engine_verify_root_v1(
                bytes.as_ptr(),
                bytes.len(),
                &mut version,
                &mut key_count,
                &mut threshold,
            )
        };

        assert_eq!(result, STATUS_OK);
        assert_eq!(version, expected_version);
        assert_eq!(key_count, expected_keys);
        assert_eq!(threshold, expected_threshold);
    }
}
