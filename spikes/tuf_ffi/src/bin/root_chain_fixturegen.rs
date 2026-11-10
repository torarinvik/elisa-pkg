//! Create ephemeral, valid root-rotation fixtures for the Elisa ABI probe.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use aws_lc_rs::{
    digest,
    rand::SystemRandom,
    signature::{Ed25519KeyPair, KeyPair as AwsKeyPair},
};
use serde_json::{json, Value};
use sigstore_tuf::{canonical_json, Key};

const FAR_FUTURE: &str = "2999-01-01T00:00:00Z";
const EXPIRED: &str = "2000-01-01T00:00:00Z";
const EXPIRY_BOUNDARY: &str = "2023-11-14T22:13:20Z";
const SNAPSHOT_SHA256: &str = "0000000000000000000000000000000000000000000000000000000000000000";

struct FixtureKeyPair(Ed25519KeyPair);

impl FixtureKeyPair {
    fn generate() -> Self {
        let pkcs8 = Ed25519KeyPair::generate_pkcs8(&SystemRandom::new())
            .expect("generate Ed25519 fixture key");
        Self(Ed25519KeyPair::from_pkcs8(pkcs8.as_ref()).expect("load Ed25519 fixture key"))
    }

    fn public_key(&self) -> &[u8] {
        self.0.public_key().as_ref()
    }

    fn sign(&self, message: &[u8]) -> Vec<u8> {
        self.0.sign(message).as_ref().to_vec()
    }
}

fn key_entry(key_pair: &FixtureKeyPair) -> (String, Value) {
    let value = json!({
        "keytype": "ed25519",
        "scheme": "ed25519",
        "keyval": { "public": hex::encode(key_pair.public_key()) },
    });
    let key: Key = serde_json::from_value(value.clone()).expect("TUF key");
    (key.key_id().expect("key id"), value)
}

fn signature(signed: &Value, key_id: &str, key_pair: &FixtureKeyPair) -> Value {
    let canonical = canonical_json::to_canonical_bytes(signed).expect("canonical JSON");
    let signature = key_pair.sign(&canonical);
    json!({ "keyid": key_id, "sig": hex::encode(signature) })
}

fn root_signed(version: u64, key_id: &str, key: Value) -> Value {
    root_signed_with_expiry(version, key_id, key, FAR_FUTURE)
}

fn root_signed_with_expiry(version: u64, key_id: &str, key: Value, expires: &str) -> Value {
    let role = json!({ "keyids": [key_id], "threshold": 1 });
    json!({
        "_type": "root",
        "spec_version": "1.0.0",
        "version": version,
        "expires": expires,
        "consistent_snapshot": true,
        "keys": { key_id: key },
        "roles": {
            "root": role,
            "timestamp": role,
            "snapshot": role,
            "targets": role,
        },
    })
}

fn timestamp_signed(version: u64, expires: &str) -> Value {
    json!({
        "_type": "timestamp",
        "spec_version": "1.0.0",
        "version": version,
        "expires": expires,
        "meta": {
            "snapshot.json": {
                "version": 1,
                "length": 2,
                "hashes": { "sha256": SNAPSHOT_SHA256 }
            }
        }
    })
}

fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(digest::digest(&digest::SHA256, bytes).as_ref())
}

fn metadata_pin(version: u64, bytes: &[u8]) -> Value {
    json!({
        "version": version,
        "length": bytes.len(),
        "hashes": { "sha256": sha256_hex(bytes) },
    })
}

fn top_targets_signed(delegated_key_id: &str, delegated_key: Value) -> Value {
    let profile_bytes = b"TUF test profile";
    json!({
        "_type": "targets",
        "spec_version": "1.0.0",
        "version": 1,
        "expires": FAR_FUTURE,
        "targets": {
            "metadata/profile.json": {
                "length": profile_bytes.len(),
                "hashes": { "sha256": sha256_hex(profile_bytes) },
            }
        },
        "delegations": {
            "keys": { delegated_key_id: delegated_key },
            "roles": [{
                "name": "package-demo",
                "keyids": [delegated_key_id],
                "threshold": 1,
                "terminating": true,
                "paths": ["packages/demo/*/*.tar"],
            }],
        },
    })
}

fn package_targets_signed(
    target_path: &str,
    archive_digest: &str,
    archive_length: usize,
    registry: &str,
    status: &str,
) -> Value {
    json!({
        "_type": "targets",
        "spec_version": "1.0.0",
        "version": 1,
        "expires": FAR_FUTURE,
        "targets": {
            target_path: {
                "length": archive_length,
                "hashes": { "sha256": archive_digest },
                "custom": {
                    "elisapkg": {
                        "schema-version": 1,
                        "registry": registry,
                        "package": "demo",
                        "version": "1.2.3",
                        "dependencies": [],
                        "elisa": "^1.0.0",
                        "archive-format": "ustar-v1",
                        "status": status,
                    }
                },
            }
        },
    })
}

fn write_package_chain(
    directory: &Path,
    prefix: &str,
    status: &str,
    corrupt_delegated_signature: bool,
    root_key_id: &str,
    root_key: &FixtureKeyPair,
    top_targets: &[u8],
    target_path: &str,
    archive_digest: &str,
    archive_length: usize,
    delegated_key_id: &str,
    delegated_key: &FixtureKeyPair,
) {
    let delegated_signed = package_targets_signed(
        target_path,
        archive_digest,
        archive_length,
        "primary",
        status,
    );
    let mut delegated_signature = signature(&delegated_signed, delegated_key_id, delegated_key);
    if corrupt_delegated_signature {
        delegated_signature["sig"] = json!("00".repeat(64));
    }
    let delegated_targets = envelope(delegated_signed, vec![delegated_signature]);

    let snapshot_signed = json!({
        "_type": "snapshot",
        "spec_version": "1.0.0",
        "version": 1,
        "expires": FAR_FUTURE,
        "meta": {
            "targets.json": metadata_pin(1, top_targets),
            "package-demo.json": metadata_pin(1, &delegated_targets),
        },
    });
    let snapshot = envelope(
        snapshot_signed.clone(),
        vec![signature(&snapshot_signed, root_key_id, root_key)],
    );

    let timestamp_signed = json!({
        "_type": "timestamp",
        "spec_version": "1.0.0",
        "version": 1,
        "expires": FAR_FUTURE,
        "meta": { "snapshot.json": metadata_pin(1, &snapshot) },
    });
    let timestamp = envelope(
        timestamp_signed.clone(),
        vec![signature(&timestamp_signed, root_key_id, root_key)],
    );

    write_fixture(directory, &format!("{prefix}-timestamp.json"), &timestamp);
    write_fixture(directory, &format!("{prefix}-snapshot.json"), &snapshot);
    write_fixture(directory, &format!("{prefix}-targets.json"), top_targets);
    write_fixture(
        directory,
        &format!("{prefix}-package-demo.json"),
        &delegated_targets,
    );
}

fn envelope(signed: Value, signatures: Vec<Value>) -> Vec<u8> {
    serde_json::to_vec(&json!({ "signed": signed, "signatures": signatures }))
        .expect("metadata envelope")
}

fn write_fixture(directory: &Path, name: &str, contents: &[u8]) {
    fs::write(directory.join(name), contents).expect("write generated TUF fixture");
}

fn main() {
    let directory = env::args_os()
        .nth(1)
        .map(PathBuf::from)
        .expect("fixture output directory argument");
    fs::create_dir_all(&directory).expect("create fixture directory");

    let key1 = FixtureKeyPair::generate();
    let key2 = FixtureKeyPair::generate();
    let key3 = FixtureKeyPair::generate();
    let key4 = FixtureKeyPair::generate();
    let (id1, entry1) = key_entry(&key1);
    let (id2, entry2) = key_entry(&key2);
    let (id3, entry3) = key_entry(&key3);
    let (id4, entry4) = key_entry(&key4);

    let root1_signed = root_signed(1, &id1, entry1);
    let root1 = envelope(
        root1_signed.clone(),
        vec![signature(&root1_signed, &id1, &key1)],
    );

    let root2_signed = root_signed_with_expiry(2, &id2, entry2, EXPIRED);
    let root2 = envelope(
        root2_signed.clone(),
        vec![
            signature(&root2_signed, &id1, &key1),
            signature(&root2_signed, &id2, &key2),
        ],
    );

    let root3_signed = root_signed(3, &id3, entry3.clone());
    let root3 = envelope(
        root3_signed.clone(),
        vec![
            signature(&root3_signed, &id2, &key2),
            signature(&root3_signed, &id3, &key3),
        ],
    );

    let expired_root_signed = root_signed_with_expiry(4, &id3, entry3, EXPIRED);
    let expired_root = envelope(
        expired_root_signed.clone(),
        vec![signature(&expired_root_signed, &id3, &key3)],
    );
    let boundary_root_signed = root_signed_with_expiry(5, &id3, entry3, EXPIRY_BOUNDARY);
    let boundary_root = envelope(
        boundary_root_signed.clone(),
        vec![signature(&boundary_root_signed, &id3, &key3)],
    );
    let timestamp = timestamp_signed(1, FAR_FUTURE);
    let timestamp = envelope(timestamp.clone(), vec![signature(&timestamp, &id3, &key3)]);
    let expired_timestamp = timestamp_signed(2, EXPIRED);
    let expired_timestamp = envelope(
        expired_timestamp.clone(),
        vec![signature(&expired_timestamp, &id3, &key3)],
    );
    let boundary_timestamp = timestamp_signed(3, EXPIRY_BOUNDARY);
    let boundary_timestamp = envelope(
        boundary_timestamp.clone(),
        vec![signature(&boundary_timestamp, &id3, &key3)],
    );

    write_fixture(&directory, "root1.json", &root1);
    write_fixture(&directory, "root2.json", &root2);
    write_fixture(&directory, "root3.json", &root3);
    write_fixture(&directory, "root-expired.json", &expired_root);
    write_fixture(&directory, "root-expiry-boundary.json", &boundary_root);
    write_fixture(&directory, "timestamp.json", &timestamp);
    write_fixture(&directory, "timestamp-expired.json", &expired_timestamp);
    write_fixture(
        &directory,
        "timestamp-expiry-boundary.json",
        &boundary_timestamp,
    );

    let archive_bytes = b"elisapkg test-only archive";
    let archive_digest = sha256_hex(archive_bytes);
    let target_path = format!("packages/demo/1.2.3/{archive_digest}.tar");
    let top_targets_signed_value = top_targets_signed(&id4, entry4);
    let top_targets = envelope(
        top_targets_signed_value.clone(),
        vec![signature(&top_targets_signed_value, &id3, &key3)],
    );
    for (prefix, status, corrupt_signature) in [
        ("published", "published", false),
        ("yanked", "yanked", false),
        ("revoked", "revoked", false),
        ("bad-signature", "published", true),
    ] {
        write_package_chain(
            &directory,
            prefix,
            status,
            corrupt_signature,
            &id3,
            &key3,
            &top_targets,
            &target_path,
            &archive_digest,
            archive_bytes.len(),
            &id4,
            &key4,
        );
    }
}
