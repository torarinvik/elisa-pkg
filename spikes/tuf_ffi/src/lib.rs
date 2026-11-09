//! Test-only C ABI proof for the pinned, transport-free TUF verifier.
//!
//! Elisa must validate the bounded metadata JSON and reject duplicate object
//! keys before calling this interface. This crate does not own persistent
//! trust state, filesystem paths, network transport, or package policy.

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::slice;

use serde_json::Value;
use sigstore_tuf::{Error as TufError, Role, Root, TrustedMetadataSet};

const ABI_VERSION: u32 = 1;
const MAX_METADATA_BYTES: usize = 1_048_576;

const STATUS_OK: i32 = 0;
const STATUS_INVALID_ARGUMENT: i32 = 1;
const STATUS_INVALID_ROOT: i32 = 2;
const STATUS_UNSUPPORTED_SPEC: i32 = 3;
const STATUS_INTERNAL_PANIC: i32 = 4;
const STATUS_EXPIRED_ROOT: i32 = 5;
const STATUS_INVALID_METADATA: i32 = 6;
const STATUS_EXPIRED_METADATA: i32 = 7;
const STATUS_UNSUPPORTED_ALGORITHM: i32 = 8;

#[derive(Debug, Clone, Copy)]
struct VerifiedRootSummary {
    version: u64,
    key_count: u32,
    root_threshold: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum VerifyError {
    InvalidRoot,
    InvalidMetadata,
    UnsupportedSpec,
    UnsupportedAlgorithm,
    ExpiredRoot,
    ExpiredMetadata,
}

#[derive(Debug, Clone, Copy)]
struct VerifiedTimestampSummary {
    version: u64,
    snapshot_version: u64,
    snapshot_length: u64,
    snapshot_sha256: [u8; 32],
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
/// ABI v1 status values are stable: 0 success, 1 invalid argument, 2 malformed
/// or cryptographically invalid root, 3 unsupported profile version,
/// 4 contained Rust panic, 5 expired root, 6 invalid metadata, 7 expired
/// active metadata, and 8 unsupported signature algorithm.
///
/// # Safety
///
/// `metadata` must point to `metadata_len` readable bytes. Each output pointer
/// must be aligned and writable for its pointee type, and the three output
/// ranges must not overlap each other or the input range. The input bytes must
/// have passed Elisa's bounded duplicate-key and canonical-number precheck
/// before this function is called.
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
        || metadata_len > MAX_METADATA_BYTES
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
        Ok(Err(error)) => return status_for_verify_error(error),
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
        || trusted_root_len > MAX_METADATA_BYTES
        || candidate_root.is_null()
        || candidate_root_len == 0
        || candidate_root_len > MAX_METADATA_BYTES
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
        Ok(Err(error)) => return status_for_verify_error(error),
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

/// Check final-root expiry at the caller's fixed refresh-start time.
///
/// This is intentionally separate from root-link verification: TUF permits
/// expired intermediate roots within a valid sequential rotation, but the
/// final trusted root must be current before refreshing active roles.
///
/// Status values are 0 success, 1 invalid arguments, 2 invalid root,
/// 3 unsupported spec, 4 contained panic, 5 expired root, 6 invalid metadata,
/// 7 expired metadata, and 8 unsupported signature algorithm.
///
/// # Safety
///
/// `metadata` must point to `metadata_len` readable bytes. The bytes must have
/// passed Elisa's bounded duplicate-key and canonical-number precheck.
/// `now_nanoseconds` must be less than one billion.
#[no_mangle]
pub unsafe extern "C" fn elisapkg_tuf_engine_check_root_expiry_v1(
    metadata: *const u8,
    metadata_len: usize,
    now_unix_seconds: i64,
    now_nanoseconds: u32,
) -> i32 {
    if metadata.is_null() || metadata_len == 0 || metadata_len > MAX_METADATA_BYTES {
        return STATUS_INVALID_ARGUMENT;
    }
    if now_nanoseconds >= 1_000_000_000 {
        return STATUS_INVALID_ARGUMENT;
    }
    let now = match jiff::Timestamp::new(now_unix_seconds, now_nanoseconds as i32) {
        Ok(now) => now,
        Err(_) => return STATUS_INVALID_ARGUMENT,
    };

    let verification = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: null and length bounds are checked above. The caller contract
        // requires `metadata` to address `metadata_len` readable bytes.
        let bytes = unsafe { slice::from_raw_parts(metadata, metadata_len) };
        check_root_expiry_bytes(bytes, now)
    }));

    match verification {
        Ok(Ok(())) => STATUS_OK,
        Ok(Err(error)) => status_for_verify_error(error),
        Err(_) => STATUS_INTERNAL_PANIC,
    }
}

/// Verify a timestamp against a self-authenticating trusted root.
///
/// This operation authenticates the timestamp role and returns its snapshot
/// pin. Elisa remains responsible for durable rollback floors and persistence.
/// The caller supplies the fixed refresh-start time at nanosecond precision.
///
/// # Safety
///
/// The two inputs must point to readable buffers that passed Elisa's bounded
/// JSON, duplicate-key, canonical-number, and SHA-256 profile prechecks. The
/// output pointers must be aligned and writable; their output ranges must not
/// overlap each other or either input range. `out_snapshot_sha256` addresses
/// exactly 32 writable bytes. `now_nanoseconds` must be less than one billion.
#[no_mangle]
pub unsafe extern "C" fn elisapkg_tuf_engine_verify_timestamp_v1(
    trusted_root: *const u8,
    trusted_root_len: usize,
    timestamp: *const u8,
    timestamp_len: usize,
    now_unix_seconds: i64,
    now_nanoseconds: u32,
    out_timestamp_version: *mut u64,
    out_snapshot_version: *mut u64,
    out_snapshot_length: *mut u64,
    out_snapshot_sha256: *mut u8,
) -> i32 {
    if trusted_root.is_null()
        || trusted_root_len == 0
        || trusted_root_len > MAX_METADATA_BYTES
        || timestamp.is_null()
        || timestamp_len == 0
        || timestamp_len > MAX_METADATA_BYTES
        || now_nanoseconds >= 1_000_000_000
        || out_timestamp_version.is_null()
        || out_snapshot_version.is_null()
        || out_snapshot_length.is_null()
        || out_snapshot_sha256.is_null()
    {
        return STATUS_INVALID_ARGUMENT;
    }
    let now = match jiff::Timestamp::new(now_unix_seconds, now_nanoseconds as i32) {
        Ok(now) => now,
        Err(_) => return STATUS_INVALID_ARGUMENT,
    };

    let verification = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: null and length bounds are checked above. The caller contract
        // requires each input pointer to address its declared readable range.
        let root_bytes = unsafe { slice::from_raw_parts(trusted_root, trusted_root_len) };
        let timestamp_bytes = unsafe { slice::from_raw_parts(timestamp, timestamp_len) };
        verify_timestamp_bytes(root_bytes, timestamp_bytes, now)
    }));

    let summary = match verification {
        Ok(Ok(summary)) => summary,
        Ok(Err(error)) => return status_for_verify_error(error),
        Err(_) => return STATUS_INTERNAL_PANIC,
    };

    // SAFETY: output pointer validity, extents, exclusive access, and
    // non-overlap are caller obligations documented above.
    unsafe {
        *out_timestamp_version = summary.version;
        *out_snapshot_version = summary.snapshot_version;
        *out_snapshot_length = summary.snapshot_length;
        std::ptr::copy_nonoverlapping(
            summary.snapshot_sha256.as_ptr(),
            out_snapshot_sha256,
            summary.snapshot_sha256.len(),
        );
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

fn check_root_expiry_bytes(bytes: &[u8], now: jiff::Timestamp) -> Result<(), VerifyError> {
    validate_root_spec_version(bytes)?;

    let trusted = TrustedMetadataSet::from_root(bytes).map_err(|_| VerifyError::InvalidRoot)?;
    // TUF requires expiry to be later than the fixed refresh start time. The
    // pinned helper uses `< now`, which would incorrectly accept equality.
    if expiration_is_at_or_before(trusted.root(), now).map_err(|_| VerifyError::InvalidRoot)? {
        Err(VerifyError::ExpiredRoot)
    } else {
        Ok(())
    }
}

fn verify_timestamp_bytes(
    root_bytes: &[u8],
    timestamp_bytes: &[u8],
    now: jiff::Timestamp,
) -> Result<VerifiedTimestampSummary, VerifyError> {
    validate_root_spec_version(root_bytes)?;
    validate_spec_version(timestamp_bytes, VerifyError::InvalidMetadata)?;

    let mut trusted =
        TrustedMetadataSet::from_root(root_bytes).map_err(|_| VerifyError::InvalidRoot)?;
    if expiration_is_at_or_before(trusted.root(), now).map_err(|_| VerifyError::InvalidRoot)? {
        return Err(VerifyError::ExpiredRoot);
    }

    trusted
        .update_timestamp(timestamp_bytes, now)
        .map_err(|error| match error {
            TufError::Expired { .. } => VerifyError::ExpiredMetadata,
            _ => VerifyError::InvalidMetadata,
        })?;
    let timestamp = trusted.timestamp().ok_or(VerifyError::InvalidMetadata)?;
    if expiration_is_at_or_before(timestamp, now).map_err(|_| VerifyError::InvalidMetadata)? {
        return Err(VerifyError::ExpiredMetadata);
    }

    // The package profile permits timestamp.json to pin only snapshot.json,
    // with both a bounded length and the required SHA-256 digest.
    if timestamp.meta.len() != 1 {
        return Err(VerifyError::InvalidMetadata);
    }
    let pin = timestamp
        .snapshot_meta()
        .ok_or(VerifyError::InvalidMetadata)?;
    let snapshot_length = pin
        .length
        .filter(|length| *length > 0 && *length <= MAX_METADATA_BYTES as u64)
        .ok_or(VerifyError::InvalidMetadata)?;
    let hashes = pin.hashes.as_ref().ok_or(VerifyError::InvalidMetadata)?;
    if hashes.len() != 1 {
        return Err(VerifyError::InvalidMetadata);
    }
    let digest = hashes.get("sha256").ok_or(VerifyError::InvalidMetadata)?;
    if digest.len() != 64
        || !digest
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(VerifyError::InvalidMetadata);
    }
    let mut snapshot_sha256 = [0_u8; 32];
    hex::decode_to_slice(digest, &mut snapshot_sha256).map_err(|_| VerifyError::InvalidMetadata)?;

    Ok(VerifiedTimestampSummary {
        version: timestamp.version,
        snapshot_version: pin.version,
        snapshot_length,
        snapshot_sha256,
    })
}

fn expiration_is_at_or_before<T: Role>(role: &T, now: jiff::Timestamp) -> Result<bool, ()> {
    role.expires()
        .parse::<jiff::Timestamp>()
        .map(|expires_at| expires_at <= now)
        .map_err(|_| ())
}

fn validate_spec_version(bytes: &[u8], malformed: VerifyError) -> Result<(), VerifyError> {
    // Elisa's bounded precheck is authoritative for duplicate-key rejection
    // and canonical integer syntax. Parse the version here to enforce this
    // package's stricter compatibility range before the upstream parser runs.
    let value: Value = serde_json::from_slice(bytes).map_err(|_| malformed)?;
    let spec_version = value
        .get("signed")
        .and_then(|signed| signed.get("spec_version"))
        .and_then(Value::as_str)
        .ok_or(malformed)?;
    if !supported_spec_version(spec_version) {
        return Err(VerifyError::UnsupportedSpec);
    }
    Ok(())
}

fn status_for_verify_error(error: VerifyError) -> i32 {
    match error {
        VerifyError::InvalidRoot => STATUS_INVALID_ROOT,
        VerifyError::InvalidMetadata => STATUS_INVALID_METADATA,
        VerifyError::UnsupportedSpec => STATUS_UNSUPPORTED_SPEC,
        VerifyError::UnsupportedAlgorithm => STATUS_UNSUPPORTED_ALGORITHM,
        VerifyError::ExpiredRoot => STATUS_EXPIRED_ROOT,
        VerifyError::ExpiredMetadata => STATUS_EXPIRED_METADATA,
    }
}

fn validate_root_spec_version(bytes: &[u8]) -> Result<(), VerifyError> {
    validate_spec_version(bytes, VerifyError::InvalidRoot)?;
    validate_root_key_profile(bytes)
}

fn validate_root_key_profile(bytes: &[u8]) -> Result<(), VerifyError> {
    let value: Value = serde_json::from_slice(bytes).map_err(|_| VerifyError::InvalidRoot)?;
    let keys = value
        .get("signed")
        .and_then(|signed| signed.get("keys"))
        .and_then(Value::as_object)
        .filter(|keys| !keys.is_empty())
        .ok_or(VerifyError::InvalidRoot)?;

    for key in keys.values() {
        let keytype = key
            .get("keytype")
            .and_then(Value::as_str)
            .ok_or(VerifyError::InvalidRoot)?;
        let scheme = key
            .get("scheme")
            .and_then(Value::as_str)
            .ok_or(VerifyError::InvalidRoot)?;
        if keytype != "ed25519" || scheme != "ed25519" {
            return Err(VerifyError::UnsupportedAlgorithm);
        }
        let public = key
            .get("keyval")
            .and_then(|keyval| keyval.get("public"))
            .and_then(Value::as_str)
            .ok_or(VerifyError::InvalidRoot)?;
        if public.len() != 64
            || !public
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return Err(VerifyError::InvalidRoot);
        }
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
                MAX_METADATA_BYTES + 1,
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
    fn root_update_abi_rejects_bad_buffers_without_writing_outputs() {
        let bytes = b"{}";
        let mut version = 0xfeed_u64;
        let mut key_count = 0xfeed_u32;
        let mut threshold = 0xfeed_u32;

        let missing_trusted = unsafe {
            elisapkg_tuf_engine_verify_root_update_v1(
                std::ptr::null(),
                bytes.len(),
                bytes.as_ptr(),
                bytes.len(),
                &mut version,
                &mut key_count,
                &mut threshold,
            )
        };
        assert_eq!(missing_trusted, STATUS_INVALID_ARGUMENT);

        let missing_candidate = unsafe {
            elisapkg_tuf_engine_verify_root_update_v1(
                bytes.as_ptr(),
                bytes.len(),
                std::ptr::null(),
                bytes.len(),
                &mut version,
                &mut key_count,
                &mut threshold,
            )
        };
        assert_eq!(missing_candidate, STATUS_INVALID_ARGUMENT);

        let oversized_candidate = unsafe {
            elisapkg_tuf_engine_verify_root_update_v1(
                bytes.as_ptr(),
                bytes.len(),
                bytes.as_ptr(),
                MAX_METADATA_BYTES + 1,
                &mut version,
                &mut key_count,
                &mut threshold,
            )
        };
        assert_eq!(oversized_candidate, STATUS_INVALID_ARGUMENT);

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
    fn rejects_a_real_root_outside_the_ed25519_profile_without_publishing() {
        let bytes = include_bytes!("../testdata/github-root.json");
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

        assert_eq!(result, STATUS_UNSUPPORTED_ALGORITHM);
        assert_eq!(version, 0xfeed_u64);
        assert_eq!(key_count, 0xfeed_u32);
        assert_eq!(threshold, 0xfeed_u32);
    }
}
