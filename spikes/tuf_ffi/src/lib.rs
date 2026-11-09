//! Test-only C ABI proof for the pinned, transport-free TUF verifier.
//!
//! Elisa must validate the bounded metadata JSON and reject duplicate object
//! keys before calling this interface. This crate does not own persistent
//! trust state, filesystem paths, network transport, or package policy.

use std::collections::BTreeSet;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::slice;

use serde_json::Value;
use sigstore_tuf::{Error as TufError, Key, Role, Root, TrustedMetadataSet};

const ABI_VERSION: u32 = 1;
const MAX_METADATA_BYTES: usize = 1_048_576;
const MAX_KEYS_PER_ROLE: usize = 64;
const MAX_SIGNATURES_PER_METADATA: usize = 64;
const MAX_ROOT_KEYS: usize = MAX_KEYS_PER_ROLE * 5;
const MAX_DELEGATED_ROLES: usize = 4_096;
const MAX_DELEGATED_KEYS: usize = 65_536;
const MAX_TARGETS_PER_ROLE: usize = 4_096;
const MAX_TARGET_PATH_BYTES: usize = 4_096;
const MAX_TARGET_BYTES: u64 = 67_108_864;

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

#[derive(Debug, Clone, Copy)]
struct VerifiedSnapshotSummary {
    version: u64,
    metadata_count: u32,
}

#[derive(Debug, Clone, Copy)]
struct VerifiedTargetsSummary {
    version: u64,
    target_count: u32,
    delegation_count: u32,
}

#[derive(Debug, Clone, Copy)]
struct VerifiedPackageTargetSummary {
    delegated_targets_version: u64,
    target_length: u64,
    target_sha256: [u8; 32],
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

/// Verify a snapshot against its timestamp pin and the trusted root.
///
/// The function re-verifies the timestamp instead of trusting a caller-supplied
/// summary, so the root, timestamp, and snapshot bytes form one checked chain.
/// It validates bounded SHA-256 metadata pins and the snapshot signature
/// threshold, then returns the authenticated snapshot version and metadata
/// entry count. The caller must persist rollback floors separately.
///
/// # Safety
///
/// The three inputs must point to readable buffers that passed Elisa's bounded
/// JSON, duplicate-key, canonical-number, and SHA-256 profile prechecks. Output
/// pointers must be aligned and writable, and the output ranges must not
/// overlap each other or any input range. `now_nanoseconds` must be less than
/// one billion.
#[no_mangle]
pub unsafe extern "C" fn elisapkg_tuf_engine_verify_snapshot_v1(
    trusted_root: *const u8,
    trusted_root_len: usize,
    timestamp: *const u8,
    timestamp_len: usize,
    snapshot: *const u8,
    snapshot_len: usize,
    now_unix_seconds: i64,
    now_nanoseconds: u32,
    out_snapshot_version: *mut u64,
    out_metadata_count: *mut u32,
) -> i32 {
    if trusted_root.is_null()
        || trusted_root_len == 0
        || trusted_root_len > MAX_METADATA_BYTES
        || timestamp.is_null()
        || timestamp_len == 0
        || timestamp_len > MAX_METADATA_BYTES
        || snapshot.is_null()
        || snapshot_len == 0
        || snapshot_len > MAX_METADATA_BYTES
        || now_nanoseconds >= 1_000_000_000
        || out_snapshot_version.is_null()
        || out_metadata_count.is_null()
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
        let snapshot_bytes = unsafe { slice::from_raw_parts(snapshot, snapshot_len) };
        verify_snapshot_bytes(root_bytes, timestamp_bytes, snapshot_bytes, now)
    }));

    let summary = match verification {
        Ok(Ok(summary)) => summary,
        Ok(Err(error)) => return status_for_verify_error(error),
        Err(_) => return STATUS_INTERNAL_PANIC,
    };

    // SAFETY: non-null output locations were checked above. Their writable,
    // non-overlapping extents are part of the caller contract.
    unsafe {
        *out_snapshot_version = summary.version;
        *out_metadata_count = summary.metadata_count;
    }
    STATUS_OK
}

/// Return one authenticated metadata pin from a snapshot.
///
/// This operation re-verifies the root, timestamp, and snapshot chain on every
/// call, then returns the requested snapshot entry's version, length, and
/// SHA-256 digest. It never exposes an unverified pin or mutates trust state.
///
/// # Safety
///
/// The three metadata inputs must point to readable buffers that passed
/// Elisa's bounded JSON, duplicate-key, canonical-number, and SHA-256 profile
/// prechecks. `metadata_name` must point to `metadata_name_len` readable bytes.
/// Output pointers must be aligned and writable; output ranges must not overlap
/// one another or any input range. `out_sha256` addresses 32 writable bytes.
/// `now_nanoseconds` must be less than one billion.
#[no_mangle]
pub unsafe extern "C" fn elisapkg_tuf_engine_get_snapshot_pin_v1(
    trusted_root: *const u8,
    trusted_root_len: usize,
    timestamp: *const u8,
    timestamp_len: usize,
    snapshot: *const u8,
    snapshot_len: usize,
    metadata_name: *const u8,
    metadata_name_len: usize,
    now_unix_seconds: i64,
    now_nanoseconds: u32,
    out_version: *mut u64,
    out_length: *mut u64,
    out_sha256: *mut u8,
) -> i32 {
    if trusted_root.is_null()
        || trusted_root_len == 0
        || trusted_root_len > MAX_METADATA_BYTES
        || timestamp.is_null()
        || timestamp_len == 0
        || timestamp_len > MAX_METADATA_BYTES
        || snapshot.is_null()
        || snapshot_len == 0
        || snapshot_len > MAX_METADATA_BYTES
        || metadata_name.is_null()
        || metadata_name_len == 0
        || metadata_name_len > 256
        || now_nanoseconds >= 1_000_000_000
        || out_version.is_null()
        || out_length.is_null()
        || out_sha256.is_null()
    {
        return STATUS_INVALID_ARGUMENT;
    }
    let now = match jiff::Timestamp::new(now_unix_seconds, now_nanoseconds as i32) {
        Ok(now) => now,
        Err(_) => return STATUS_INVALID_ARGUMENT,
    };

    let verification = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: null and length bounds are checked above. The caller contract
        // requires every input pointer to address its declared readable range.
        let root_bytes = unsafe { slice::from_raw_parts(trusted_root, trusted_root_len) };
        let timestamp_bytes = unsafe { slice::from_raw_parts(timestamp, timestamp_len) };
        let snapshot_bytes = unsafe { slice::from_raw_parts(snapshot, snapshot_len) };
        let name_bytes = unsafe { slice::from_raw_parts(metadata_name, metadata_name_len) };
        verify_snapshot_pin_bytes(root_bytes, timestamp_bytes, snapshot_bytes, name_bytes, now)
    }));

    let pin = match verification {
        Ok(Ok(pin)) => pin,
        Ok(Err(error)) => return status_for_verify_error(error),
        Err(_) => return STATUS_INTERNAL_PANIC,
    };

    // SAFETY: non-null output locations were checked above. Their writable,
    // non-overlapping extents are part of the caller contract.
    unsafe {
        *out_version = pin.version;
        *out_length = pin.length;
        std::ptr::copy_nonoverlapping(pin.sha256.as_ptr(), out_sha256, pin.sha256.len());
    }
    STATUS_OK
}

/// Verify top-level Targets metadata against the trusted root and snapshot.
///
/// The root→timestamp→snapshot chain is re-verified in this call. The top-level
/// Targets threshold is checked against the root, all direct target records are
/// bounded and SHA-256-only, and package target paths are reserved for package
/// delegations. Delegation keys and package-scope declarations are validated,
/// but delegated Targets files and target selection are separate operations.
///
/// # Safety
///
/// The four metadata inputs must point to readable buffers that passed
/// Elisa's bounded JSON, duplicate-key, canonical-number, and SHA-256 profile
/// prechecks. Output pointers must be aligned and writable; their ranges must
/// not overlap each other or any input range. `now_nanoseconds` must be less
/// than one billion.
#[no_mangle]
pub unsafe extern "C" fn elisapkg_tuf_engine_verify_targets_v1(
    trusted_root: *const u8,
    trusted_root_len: usize,
    timestamp: *const u8,
    timestamp_len: usize,
    snapshot: *const u8,
    snapshot_len: usize,
    targets: *const u8,
    targets_len: usize,
    now_unix_seconds: i64,
    now_nanoseconds: u32,
    out_targets_version: *mut u64,
    out_target_count: *mut u32,
    out_delegation_count: *mut u32,
) -> i32 {
    if trusted_root.is_null()
        || trusted_root_len == 0
        || trusted_root_len > MAX_METADATA_BYTES
        || timestamp.is_null()
        || timestamp_len == 0
        || timestamp_len > MAX_METADATA_BYTES
        || snapshot.is_null()
        || snapshot_len == 0
        || snapshot_len > MAX_METADATA_BYTES
        || targets.is_null()
        || targets_len == 0
        || targets_len > MAX_METADATA_BYTES
        || now_nanoseconds >= 1_000_000_000
        || out_targets_version.is_null()
        || out_target_count.is_null()
        || out_delegation_count.is_null()
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
        let snapshot_bytes = unsafe { slice::from_raw_parts(snapshot, snapshot_len) };
        let targets_bytes = unsafe { slice::from_raw_parts(targets, targets_len) };
        verify_top_level_targets_bytes(
            root_bytes,
            timestamp_bytes,
            snapshot_bytes,
            targets_bytes,
            now,
        )
    }));

    let summary = match verification {
        Ok(Ok(summary)) => summary,
        Ok(Err(error)) => return status_for_verify_error(error),
        Err(_) => return STATUS_INTERNAL_PANIC,
    };

    // SAFETY: non-null output locations were checked above. Their writable,
    // non-overlapping extents are part of the caller contract.
    unsafe {
        *out_targets_version = summary.version;
        *out_target_count = summary.target_count;
        *out_delegation_count = summary.delegation_count;
    }
    STATUS_OK
}

/// Verify one package-scoped delegated Targets role and select an authenticated
/// package target from it.
///
/// The package role name is `package-<package_name>`. The full root → timestamp
/// → snapshot → top-level Targets chain and the delegated role are re-verified
/// for every call. The selected target must use the profile path
/// `packages/<package>/<stable-version>/<sha256>.tar`, and its filename digest
/// must equal its signed SHA-256 target hash.
///
/// # Safety
///
/// The five metadata inputs must point to readable buffers that passed
/// Elisa's bounded JSON, duplicate-key, canonical-number, and SHA-256 profile
/// prechecks. The package name and target path must point to readable UTF-8
/// buffers with the declared lengths. Output pointers must be aligned and
/// writable; their ranges must not overlap each other or any input range. The
/// SHA-256 output must address 32 writable bytes. `now_nanoseconds` must be
/// less than one billion.
#[no_mangle]
pub unsafe extern "C" fn elisapkg_tuf_engine_verify_package_target_v1(
    trusted_root: *const u8,
    trusted_root_len: usize,
    timestamp: *const u8,
    timestamp_len: usize,
    snapshot: *const u8,
    snapshot_len: usize,
    targets: *const u8,
    targets_len: usize,
    delegated_targets: *const u8,
    delegated_targets_len: usize,
    package_name: *const u8,
    package_name_len: usize,
    target_path: *const u8,
    target_path_len: usize,
    now_unix_seconds: i64,
    now_nanoseconds: u32,
    out_delegated_targets_version: *mut u64,
    out_target_length: *mut u64,
    out_target_sha256: *mut u8,
) -> i32 {
    if trusted_root.is_null()
        || trusted_root_len == 0
        || trusted_root_len > MAX_METADATA_BYTES
        || timestamp.is_null()
        || timestamp_len == 0
        || timestamp_len > MAX_METADATA_BYTES
        || snapshot.is_null()
        || snapshot_len == 0
        || snapshot_len > MAX_METADATA_BYTES
        || targets.is_null()
        || targets_len == 0
        || targets_len > MAX_METADATA_BYTES
        || delegated_targets.is_null()
        || delegated_targets_len == 0
        || delegated_targets_len > MAX_METADATA_BYTES
        || package_name.is_null()
        || package_name_len == 0
        || package_name_len > 64
        || target_path.is_null()
        || target_path_len == 0
        || target_path_len > MAX_TARGET_PATH_BYTES
        || now_nanoseconds >= 1_000_000_000
        || out_delegated_targets_version.is_null()
        || out_target_length.is_null()
        || out_target_sha256.is_null()
    {
        return STATUS_INVALID_ARGUMENT;
    }
    let now = match jiff::Timestamp::new(now_unix_seconds, now_nanoseconds as i32) {
        Ok(now) => now,
        Err(_) => return STATUS_INVALID_ARGUMENT,
    };

    let verification = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: null and length bounds are checked above. The caller contract
        // requires every pointer to address its declared readable range.
        let root_bytes = unsafe { slice::from_raw_parts(trusted_root, trusted_root_len) };
        let timestamp_bytes = unsafe { slice::from_raw_parts(timestamp, timestamp_len) };
        let snapshot_bytes = unsafe { slice::from_raw_parts(snapshot, snapshot_len) };
        let targets_bytes = unsafe { slice::from_raw_parts(targets, targets_len) };
        let delegated_targets_bytes =
            unsafe { slice::from_raw_parts(delegated_targets, delegated_targets_len) };
        let package_name_bytes = unsafe { slice::from_raw_parts(package_name, package_name_len) };
        let target_path_bytes = unsafe { slice::from_raw_parts(target_path, target_path_len) };
        let package_name =
            std::str::from_utf8(package_name_bytes).map_err(|_| VerifyError::InvalidMetadata)?;
        let target_path =
            std::str::from_utf8(target_path_bytes).map_err(|_| VerifyError::InvalidMetadata)?;
        verify_package_target_bytes(
            root_bytes,
            timestamp_bytes,
            snapshot_bytes,
            targets_bytes,
            delegated_targets_bytes,
            package_name,
            target_path,
            now,
        )
    }));

    let summary = match verification {
        Ok(Ok(summary)) => summary,
        Ok(Err(error)) => return status_for_verify_error(error),
        Err(_) => return STATUS_INTERNAL_PANIC,
    };

    // SAFETY: non-null output locations were checked above. Their writable,
    // non-overlapping extents are part of the caller contract.
    unsafe {
        *out_delegated_targets_version = summary.delegated_targets_version;
        *out_target_length = summary.target_length;
        std::ptr::copy_nonoverlapping(summary.target_sha256.as_ptr(), out_target_sha256, 32);
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
    // The pinned helper checks `trusted_version + 1`. Refuse the terminal
    // integer before that addition so debug builds cannot panic and release
    // builds cannot wrap the sequence back to zero.
    if trusted.root().version == u64::MAX {
        return Err(VerifyError::InvalidRoot);
    }
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
    validate_signature_profile(timestamp_bytes, VerifyError::InvalidMetadata)?;
    let snapshot_pin = validate_timestamp_snapshot_pin(timestamp_bytes)?;

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
    Ok(VerifiedTimestampSummary {
        version: timestamp.version,
        snapshot_version: snapshot_pin.version,
        snapshot_length: snapshot_pin.length,
        snapshot_sha256: snapshot_pin.sha256,
    })
}

fn verify_top_level_targets_bytes(
    root_bytes: &[u8],
    timestamp_bytes: &[u8],
    snapshot_bytes: &[u8],
    targets_bytes: &[u8],
    now: jiff::Timestamp,
) -> Result<VerifiedTargetsSummary, VerifyError> {
    let mut trusted = load_verified_snapshot(root_bytes, timestamp_bytes, snapshot_bytes, now)?;
    validate_spec_version(targets_bytes, VerifyError::InvalidMetadata)?;
    validate_signature_profile(targets_bytes, VerifyError::InvalidMetadata)?;
    let (target_count, delegation_count) = validate_top_level_targets_profile(targets_bytes)?;

    let targets = trusted
        .update_targets(targets_bytes, now)
        .map_err(|error| match error {
            TufError::Expired { .. } => VerifyError::ExpiredMetadata,
            _ => VerifyError::InvalidMetadata,
        })?;
    if expiration_is_at_or_before(targets, now).map_err(|_| VerifyError::InvalidMetadata)? {
        return Err(VerifyError::ExpiredMetadata);
    }

    Ok(VerifiedTargetsSummary {
        version: targets.version,
        target_count,
        delegation_count,
    })
}

fn verify_package_target_bytes(
    root_bytes: &[u8],
    timestamp_bytes: &[u8],
    snapshot_bytes: &[u8],
    targets_bytes: &[u8],
    delegated_targets_bytes: &[u8],
    package_name: &str,
    target_path: &str,
    now: jiff::Timestamp,
) -> Result<VerifiedPackageTargetSummary, VerifyError> {
    if !valid_profile_package_name(package_name)
        || package_target_path_digest(target_path, package_name).is_none()
    {
        return Err(VerifyError::InvalidMetadata);
    }

    let mut trusted = load_verified_snapshot(root_bytes, timestamp_bytes, snapshot_bytes, now)?;
    validate_spec_version(targets_bytes, VerifyError::InvalidMetadata)?;
    validate_signature_profile(targets_bytes, VerifyError::InvalidMetadata)?;
    validate_top_level_targets_profile(targets_bytes)?;
    {
        let top_level_targets = trusted
            .update_targets(targets_bytes, now)
            .map_err(|error| match error {
                TufError::Expired { .. } => VerifyError::ExpiredMetadata,
                _ => VerifyError::InvalidMetadata,
            })?;
        if expiration_is_at_or_before(top_level_targets, now)
            .map_err(|_| VerifyError::InvalidMetadata)?
        {
            return Err(VerifyError::ExpiredMetadata);
        }
    }

    validate_spec_version(delegated_targets_bytes, VerifyError::InvalidMetadata)?;
    validate_signature_profile(delegated_targets_bytes, VerifyError::InvalidMetadata)?;
    validate_package_targets_profile(delegated_targets_bytes, package_name)?;
    let role_name = format!("package-{package_name}");
    let delegated = trusted
        .update_delegated_targets(delegated_targets_bytes, &role_name, "targets", now)
        .map_err(|error| match error {
            TufError::Expired { .. } => VerifyError::ExpiredMetadata,
            _ => VerifyError::InvalidMetadata,
        })?;
    if expiration_is_at_or_before(delegated, now).map_err(|_| VerifyError::InvalidMetadata)? {
        return Err(VerifyError::ExpiredMetadata);
    }

    let target = delegated
        .target(target_path)
        .ok_or(VerifyError::InvalidMetadata)?;
    let target_length = target.length;
    if target_length == 0 || target_length > MAX_TARGET_BYTES {
        return Err(VerifyError::InvalidMetadata);
    }
    let target_digest = target
        .hashes
        .get("sha256")
        .filter(|digest| is_lower_hex(digest, 64))
        .ok_or(VerifyError::InvalidMetadata)?;
    if target.hashes.len() != 1
        || package_target_path_digest(target_path, package_name) != Some(target_digest.as_str())
    {
        return Err(VerifyError::InvalidMetadata);
    }
    let mut target_sha256 = [0_u8; 32];
    hex::decode_to_slice(target_digest, &mut target_sha256)
        .map_err(|_| VerifyError::InvalidMetadata)?;

    Ok(VerifiedPackageTargetSummary {
        delegated_targets_version: delegated.version,
        target_length,
        target_sha256,
    })
}

fn validate_top_level_targets_profile(bytes: &[u8]) -> Result<(u32, u32), VerifyError> {
    let value: Value = serde_json::from_slice(bytes).map_err(|_| VerifyError::InvalidMetadata)?;
    let signed = value
        .get("signed")
        .and_then(Value::as_object)
        .ok_or(VerifyError::InvalidMetadata)?;
    let targets = signed
        .get("targets")
        .and_then(Value::as_object)
        .filter(|targets| targets.len() <= MAX_TARGETS_PER_ROLE)
        .ok_or(VerifyError::InvalidMetadata)?;

    for (path, target) in targets {
        if !valid_profile_target_path(path) || path.starts_with("packages/") {
            return Err(VerifyError::InvalidMetadata);
        }
        validate_target_record(target)?;
    }

    let delegation_count = match signed.get("delegations") {
        None => 0,
        Some(delegations) => validate_package_delegations(delegations)?,
    };
    Ok((
        u32::try_from(targets.len()).map_err(|_| VerifyError::InvalidMetadata)?,
        delegation_count,
    ))
}

fn validate_target_record(target: &Value) -> Result<(), VerifyError> {
    target
        .get("length")
        .and_then(Value::as_u64)
        .filter(|length| *length > 0 && *length <= MAX_TARGET_BYTES)
        .ok_or(VerifyError::InvalidMetadata)?;
    let hashes = target
        .get("hashes")
        .and_then(Value::as_object)
        .filter(|hashes| hashes.len() == 1)
        .ok_or(VerifyError::InvalidMetadata)?;
    hashes
        .get("sha256")
        .and_then(Value::as_str)
        .filter(|digest| is_lower_hex(digest, 64))
        .ok_or(VerifyError::InvalidMetadata)?;
    Ok(())
}

fn validate_package_delegations(delegations: &Value) -> Result<u32, VerifyError> {
    let delegations = delegations
        .as_object()
        .ok_or(VerifyError::InvalidMetadata)?;
    let keys = delegations
        .get("keys")
        .and_then(Value::as_object)
        .ok_or(VerifyError::InvalidMetadata)?;
    let roles = delegations
        .get("roles")
        .and_then(Value::as_array)
        .filter(|roles| roles.len() <= MAX_DELEGATED_ROLES)
        .ok_or(VerifyError::InvalidMetadata)?;
    validate_key_map(keys, MAX_DELEGATED_KEYS, true, VerifyError::InvalidMetadata)?;

    let mut role_names = BTreeSet::new();
    let mut package_scopes = BTreeSet::new();
    for role in roles {
        let name = role
            .get("name")
            .and_then(Value::as_str)
            .filter(|name| !name.is_empty() && name.len() <= 256)
            .ok_or(VerifyError::InvalidMetadata)?;
        if matches!(name, "root" | "timestamp" | "snapshot" | "targets") || !role_names.insert(name)
        {
            return Err(VerifyError::InvalidMetadata);
        }
        if role.get("terminating").and_then(Value::as_bool) != Some(true)
            || role.get("path_hash_prefixes").is_some()
        {
            return Err(VerifyError::InvalidMetadata);
        }
        let paths = role
            .get("paths")
            .and_then(Value::as_array)
            .filter(|paths| paths.len() == 1)
            .ok_or(VerifyError::InvalidMetadata)?;
        let pattern = paths[0].as_str().ok_or(VerifyError::InvalidMetadata)?;
        let package =
            package_from_delegation_pattern(pattern).ok_or(VerifyError::InvalidMetadata)?;
        if name.strip_prefix("package-") != Some(package) || !package_scopes.insert(package) {
            return Err(VerifyError::InvalidMetadata);
        }

        let key_ids = role
            .get("keyids")
            .and_then(Value::as_array)
            .filter(|key_ids| !key_ids.is_empty() && key_ids.len() <= MAX_KEYS_PER_ROLE)
            .ok_or(VerifyError::InvalidMetadata)?;
        role.get("threshold")
            .and_then(Value::as_u64)
            .filter(|threshold| *threshold > 0 && *threshold <= key_ids.len() as u64)
            .ok_or(VerifyError::InvalidMetadata)?;
        let mut seen_key_ids = BTreeSet::new();
        for key_id in key_ids {
            let key_id = key_id.as_str().ok_or(VerifyError::InvalidMetadata)?;
            if !is_lower_hex(key_id, 64)
                || !keys.contains_key(key_id)
                || !seen_key_ids.insert(key_id)
            {
                return Err(VerifyError::InvalidMetadata);
            }
        }
    }

    u32::try_from(roles.len()).map_err(|_| VerifyError::InvalidMetadata)
}

fn validate_package_targets_profile(bytes: &[u8], package_name: &str) -> Result<u32, VerifyError> {
    let value: Value = serde_json::from_slice(bytes).map_err(|_| VerifyError::InvalidMetadata)?;
    let signed = value
        .get("signed")
        .and_then(Value::as_object)
        .ok_or(VerifyError::InvalidMetadata)?;
    if signed.contains_key("delegations") {
        return Err(VerifyError::InvalidMetadata);
    }
    let targets = signed
        .get("targets")
        .and_then(Value::as_object)
        .filter(|targets| targets.len() <= MAX_TARGETS_PER_ROLE)
        .ok_or(VerifyError::InvalidMetadata)?;

    let mut package_versions = BTreeSet::new();
    for (path, target) in targets {
        let path_digest =
            package_target_path_digest(path, package_name).ok_or(VerifyError::InvalidMetadata)?;
        let package_version = path.split('/').nth(2).ok_or(VerifyError::InvalidMetadata)?;
        if !package_versions.insert(package_version) {
            return Err(VerifyError::InvalidMetadata);
        }
        validate_target_record(target)?;
        let metadata_digest = target
            .get("hashes")
            .and_then(|hashes| hashes.get("sha256"))
            .and_then(Value::as_str)
            .ok_or(VerifyError::InvalidMetadata)?;
        if metadata_digest != path_digest {
            return Err(VerifyError::InvalidMetadata);
        }
    }

    u32::try_from(targets.len()).map_err(|_| VerifyError::InvalidMetadata)
}

fn package_from_delegation_pattern(pattern: &str) -> Option<&str> {
    let package_and_glob = pattern.strip_prefix("packages/")?;
    let (package, glob) = package_and_glob.split_once('/')?;
    if glob != "*/*.tar" || !valid_profile_package_name(package) {
        return None;
    }
    Some(package)
}

fn package_target_path_digest<'a>(path: &'a str, expected_package: &str) -> Option<&'a str> {
    if !valid_profile_target_path(path) {
        return None;
    }
    let mut segments = path.split('/');
    if segments.next()? != "packages" || segments.next()? != expected_package {
        return None;
    }
    if !valid_stable_profile_version(segments.next()?) {
        return None;
    }
    let filename = segments.next()?;
    if segments.next().is_some() {
        return None;
    }
    let digest = filename.strip_suffix(".tar")?;
    is_lower_hex(digest, 64).then_some(digest)
}

fn valid_stable_profile_version(value: &str) -> bool {
    let mut components = value.split('.');
    let (Some(major), Some(minor), Some(patch), None) = (
        components.next(),
        components.next(),
        components.next(),
        components.next(),
    ) else {
        return false;
    };
    [major, minor, patch].into_iter().all(|component| {
        !component.is_empty()
            && !(component.len() > 1 && component.starts_with('0'))
            && component.bytes().all(|byte| byte.is_ascii_digit())
            && component.parse::<u64>().is_ok()
    })
}

fn valid_profile_package_name(value: &str) -> bool {
    if value.is_empty() || value.len() > 64 {
        return false;
    }
    let bytes = value.as_bytes();
    if !bytes[0].is_ascii_lowercase() {
        return false;
    }
    let mut previous_hyphen = false;
    for (index, byte) in bytes.iter().copied().enumerate() {
        let valid = byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-';
        if !valid || (byte == b'-' && (index == 0 || index + 1 == bytes.len() || previous_hyphen)) {
            return false;
        }
        previous_hyphen = byte == b'-';
    }
    true
}

fn valid_profile_target_path(path: &str) -> bool {
    if path.is_empty() || path.len() > MAX_TARGET_PATH_BYTES || !path.is_ascii() {
        return false;
    }
    if path.starts_with('/')
        || path.ends_with('/')
        || path.contains('\\')
        || path.contains(':')
        || path.bytes().any(|byte| !(0x21..=0x7e).contains(&byte))
    {
        return false;
    }
    path.split('/')
        .all(|segment| !segment.is_empty() && segment != "." && segment != "..")
}

fn verify_snapshot_bytes(
    root_bytes: &[u8],
    timestamp_bytes: &[u8],
    snapshot_bytes: &[u8],
    now: jiff::Timestamp,
) -> Result<VerifiedSnapshotSummary, VerifyError> {
    let trusted = load_verified_snapshot(root_bytes, timestamp_bytes, snapshot_bytes, now)?;
    let snapshot = trusted.snapshot().ok_or(VerifyError::InvalidMetadata)?;

    Ok(VerifiedSnapshotSummary {
        version: snapshot.version,
        metadata_count: u32::try_from(snapshot.meta.len())
            .map_err(|_| VerifyError::InvalidMetadata)?,
    })
}

fn verify_snapshot_pin_bytes(
    root_bytes: &[u8],
    timestamp_bytes: &[u8],
    snapshot_bytes: &[u8],
    metadata_name: &[u8],
    now: jiff::Timestamp,
) -> Result<VerifiedMetadataPin, VerifyError> {
    if metadata_name.contains(&0) {
        return Err(VerifyError::InvalidMetadata);
    }
    let metadata_name =
        std::str::from_utf8(metadata_name).map_err(|_| VerifyError::InvalidMetadata)?;
    let trusted = load_verified_snapshot(root_bytes, timestamp_bytes, snapshot_bytes, now)?;
    let snapshot = trusted.snapshot().ok_or(VerifyError::InvalidMetadata)?;
    let pin = snapshot
        .meta
        .get(metadata_name)
        .ok_or(VerifyError::InvalidMetadata)?;
    let version = pin.version;
    if version == 0 {
        return Err(VerifyError::InvalidMetadata);
    }
    let length = pin
        .length
        .filter(|length| *length > 0 && *length <= MAX_METADATA_BYTES as u64)
        .ok_or(VerifyError::InvalidMetadata)?;
    let hashes = pin.hashes.as_ref().ok_or(VerifyError::InvalidMetadata)?;
    if hashes.len() != 1 {
        return Err(VerifyError::InvalidMetadata);
    }
    let digest = hashes
        .get("sha256")
        .filter(|digest| is_lower_hex(digest, 64))
        .ok_or(VerifyError::InvalidMetadata)?;
    let mut sha256 = [0_u8; 32];
    hex::decode_to_slice(digest, &mut sha256).map_err(|_| VerifyError::InvalidMetadata)?;

    Ok(VerifiedMetadataPin {
        version,
        length,
        sha256,
    })
}

fn load_verified_snapshot(
    root_bytes: &[u8],
    timestamp_bytes: &[u8],
    snapshot_bytes: &[u8],
    now: jiff::Timestamp,
) -> Result<TrustedMetadataSet, VerifyError> {
    validate_root_spec_version(root_bytes)?;
    validate_spec_version(timestamp_bytes, VerifyError::InvalidMetadata)?;
    validate_signature_profile(timestamp_bytes, VerifyError::InvalidMetadata)?;
    validate_timestamp_snapshot_pin(timestamp_bytes)?;
    validate_spec_version(snapshot_bytes, VerifyError::InvalidMetadata)?;
    validate_signature_profile(snapshot_bytes, VerifyError::InvalidMetadata)?;
    validate_snapshot_profile(snapshot_bytes)?;

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
    trusted
        .update_snapshot(snapshot_bytes, now)
        .map_err(|error| match error {
            TufError::Expired { .. } => VerifyError::ExpiredMetadata,
            _ => VerifyError::InvalidMetadata,
        })?;
    let snapshot = trusted.snapshot().ok_or(VerifyError::InvalidMetadata)?;
    if expiration_is_at_or_before(snapshot, now).map_err(|_| VerifyError::InvalidMetadata)? {
        return Err(VerifyError::ExpiredMetadata);
    }
    Ok(trusted)
}

#[derive(Debug, Clone, Copy)]
struct VerifiedMetadataPin {
    version: u64,
    length: u64,
    sha256: [u8; 32],
}

fn validate_timestamp_snapshot_pin(bytes: &[u8]) -> Result<VerifiedMetadataPin, VerifyError> {
    let value: Value = serde_json::from_slice(bytes).map_err(|_| VerifyError::InvalidMetadata)?;
    let timestamp = value
        .get("signed")
        .and_then(|signed| signed.get("meta"))
        .and_then(Value::as_object)
        .filter(|meta| meta.len() == 1)
        .ok_or(VerifyError::InvalidMetadata)?;
    let pin = timestamp
        .get("snapshot.json")
        .ok_or(VerifyError::InvalidMetadata)?;
    let version = pin
        .get("version")
        .and_then(Value::as_u64)
        .filter(|version| *version > 0)
        .ok_or(VerifyError::InvalidMetadata)?;
    let length = pin
        .get("length")
        .and_then(Value::as_u64)
        .filter(|length| *length > 0 && *length <= MAX_METADATA_BYTES as u64)
        .ok_or(VerifyError::InvalidMetadata)?;
    let hashes = pin
        .get("hashes")
        .and_then(Value::as_object)
        .filter(|hashes| hashes.len() == 1)
        .ok_or(VerifyError::InvalidMetadata)?;
    let digest = hashes
        .get("sha256")
        .and_then(Value::as_str)
        .filter(|digest| is_lower_hex(digest, 64))
        .ok_or(VerifyError::InvalidMetadata)?;
    let mut sha256 = [0_u8; 32];
    hex::decode_to_slice(digest, &mut sha256).map_err(|_| VerifyError::InvalidMetadata)?;

    Ok(VerifiedMetadataPin {
        version,
        length,
        sha256,
    })
}

fn validate_snapshot_profile(bytes: &[u8]) -> Result<u32, VerifyError> {
    let value: Value = serde_json::from_slice(bytes).map_err(|_| VerifyError::InvalidMetadata)?;
    let metadata = value
        .get("signed")
        .and_then(|signed| signed.get("meta"))
        .and_then(Value::as_object)
        .filter(|meta| {
            !meta.is_empty()
                && meta.len() <= MAX_DELEGATED_ROLES + 1
                && meta.contains_key("targets.json")
        })
        .ok_or(VerifyError::InvalidMetadata)?;

    for pin in metadata.values() {
        pin.get("version")
            .and_then(Value::as_u64)
            .filter(|version| *version > 0)
            .ok_or(VerifyError::InvalidMetadata)?;
        pin.get("length")
            .and_then(Value::as_u64)
            .filter(|length| *length > 0 && *length <= MAX_METADATA_BYTES as u64)
            .ok_or(VerifyError::InvalidMetadata)?;
        let hashes = pin
            .get("hashes")
            .and_then(Value::as_object)
            .filter(|hashes| hashes.len() == 1)
            .ok_or(VerifyError::InvalidMetadata)?;
        hashes
            .get("sha256")
            .and_then(Value::as_str)
            .filter(|digest| is_lower_hex(digest, 64))
            .ok_or(VerifyError::InvalidMetadata)?;
    }

    u32::try_from(metadata.len()).map_err(|_| VerifyError::InvalidMetadata)
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
    let signed = value
        .get("signed")
        .and_then(Value::as_object)
        .ok_or(malformed)?;
    signed
        .get("version")
        .and_then(Value::as_u64)
        .filter(|version| *version > 0)
        .ok_or(malformed)?;
    let spec_version = signed
        .get("spec_version")
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
    validate_root_key_profile(bytes)?;
    validate_root_roles_profile(bytes)?;
    validate_signature_profile(bytes, VerifyError::InvalidRoot)
}

fn validate_root_key_profile(bytes: &[u8]) -> Result<(), VerifyError> {
    let value: Value = serde_json::from_slice(bytes).map_err(|_| VerifyError::InvalidRoot)?;
    let keys = value
        .get("signed")
        .and_then(|signed| signed.get("keys"))
        .and_then(Value::as_object)
        .ok_or(VerifyError::InvalidRoot)?;
    validate_key_map(keys, MAX_ROOT_KEYS, false, VerifyError::InvalidRoot)
}

fn validate_key_map(
    keys: &serde_json::Map<String, Value>,
    max_keys: usize,
    allow_empty: bool,
    malformed: VerifyError,
) -> Result<(), VerifyError> {
    if (!allow_empty && keys.is_empty()) || keys.len() > max_keys {
        return Err(malformed);
    }
    for (key_id, key) in keys {
        if !is_lower_hex(key_id, 64) {
            return Err(malformed);
        }
        let parsed_key: Key = serde_json::from_value(key.clone()).map_err(|_| malformed)?;
        let calculated_key_id = parsed_key.key_id().map_err(|_| malformed)?;
        if calculated_key_id.as_str() != key_id.as_str() {
            return Err(malformed);
        }
        let keytype = key
            .get("keytype")
            .and_then(Value::as_str)
            .ok_or(malformed)?;
        let scheme = key.get("scheme").and_then(Value::as_str).ok_or(malformed)?;
        if keytype != "ed25519" || scheme != "ed25519" {
            return Err(VerifyError::UnsupportedAlgorithm);
        }
        let public = key
            .get("keyval")
            .and_then(|keyval| keyval.get("public"))
            .and_then(Value::as_str)
            .ok_or(malformed)?;
        if public.len() != 64
            || !public
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return Err(malformed);
        }
    }
    Ok(())
}

fn validate_root_roles_profile(bytes: &[u8]) -> Result<(), VerifyError> {
    let value: Value = serde_json::from_slice(bytes).map_err(|_| VerifyError::InvalidRoot)?;
    let root = value
        .get("signed")
        .and_then(|signed| signed.as_object())
        .ok_or(VerifyError::InvalidRoot)?;
    if root.get("consistent_snapshot").and_then(Value::as_bool) != Some(true) {
        return Err(VerifyError::InvalidRoot);
    }
    let keys = root
        .get("keys")
        .and_then(Value::as_object)
        .ok_or(VerifyError::InvalidRoot)?;
    let roles = root
        .get("roles")
        .and_then(Value::as_object)
        .filter(|roles| (4..=5).contains(&roles.len()))
        .ok_or(VerifyError::InvalidRoot)?;
    for required in ["root", "timestamp", "snapshot", "targets"] {
        if !roles.contains_key(required) {
            return Err(VerifyError::InvalidRoot);
        }
    }

    for (role_name, role) in roles {
        if !matches!(
            role_name.as_str(),
            "root" | "timestamp" | "snapshot" | "targets" | "mirrors"
        ) {
            return Err(VerifyError::InvalidRoot);
        }
        let key_ids = role
            .get("keyids")
            .and_then(Value::as_array)
            .filter(|key_ids| !key_ids.is_empty() && key_ids.len() <= MAX_KEYS_PER_ROLE)
            .ok_or(VerifyError::InvalidRoot)?;
        if role
            .get("threshold")
            .and_then(Value::as_u64)
            .filter(|threshold| *threshold > 0 && *threshold <= key_ids.len() as u64)
            .is_none()
        {
            return Err(VerifyError::InvalidRoot);
        }

        let mut seen = BTreeSet::new();
        for key_id in key_ids {
            let key_id = key_id.as_str().ok_or(VerifyError::InvalidRoot)?;
            if !is_lower_hex(key_id, 64) || !keys.contains_key(key_id) || !seen.insert(key_id) {
                return Err(VerifyError::InvalidRoot);
            }
        }
    }
    Ok(())
}

fn validate_signature_profile(bytes: &[u8], malformed: VerifyError) -> Result<(), VerifyError> {
    let value: Value = serde_json::from_slice(bytes).map_err(|_| malformed)?;
    let signatures = value
        .get("signatures")
        .and_then(Value::as_array)
        .filter(|signatures| signatures.len() <= MAX_SIGNATURES_PER_METADATA)
        .ok_or(malformed)?;
    let mut seen = BTreeSet::new();
    for signature in signatures {
        let key_id = signature
            .get("keyid")
            .and_then(Value::as_str)
            .ok_or(malformed)?;
        if !is_lower_hex(key_id, 64) || !seen.insert(key_id) {
            return Err(malformed);
        }
        let signature_bytes = signature
            .get("sig")
            .and_then(Value::as_str)
            .ok_or(malformed)?;
        if signature_bytes.len() != 128
            || !signature_bytes.bytes().all(|byte| byte.is_ascii_hexdigit())
        {
            return Err(malformed);
        }
    }
    Ok(())
}

fn is_lower_hex(value: &str, expected_len: usize) -> bool {
    value.len() == expected_len
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
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
