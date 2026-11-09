//! Create ephemeral, valid root-rotation fixtures for the Elisa ABI probe.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use serde_json::{json, Value};
use sigstore_crypto::KeyPair;
use sigstore_tuf::{canonical_json, Key};

const FAR_FUTURE: &str = "2999-01-01T00:00:00Z";

fn key_entry(key_pair: &KeyPair) -> (String, Value) {
    let public_key = key_pair.public_key_der().expect("public key").to_pem();
    let value = json!({
        "keytype": "ecdsa",
        "scheme": "ecdsa-sha2-nistp256",
        "keyval": { "public": public_key },
    });
    let key: Key = serde_json::from_value(value.clone()).expect("TUF key");
    (key.key_id().expect("key id"), value)
}

fn signature(signed: &Value, key_id: &str, key_pair: &KeyPair) -> Value {
    let canonical = canonical_json::to_canonical_bytes(signed).expect("canonical JSON");
    let signature = key_pair.sign(&canonical).expect("root signature");
    json!({ "keyid": key_id, "sig": hex::encode(signature.as_bytes()) })
}

fn root_signed(version: u64, key_id: &str, key: Value) -> Value {
    let role = json!({ "keyids": [key_id], "threshold": 1 });
    json!({
        "_type": "root",
        "spec_version": "1.0.0",
        "version": version,
        "expires": FAR_FUTURE,
        "consistent_snapshot": false,
        "keys": { key_id: key },
        "roles": {
            "root": role,
            "timestamp": role,
            "snapshot": role,
            "targets": role,
        },
    })
}

fn envelope(signed: Value, signatures: Vec<Value>) -> Vec<u8> {
    serde_json::to_vec(&json!({ "signed": signed, "signatures": signatures }))
        .expect("metadata envelope")
}

fn write_fixture(directory: &Path, name: &str, contents: &[u8]) {
    fs::write(directory.join(name), contents).expect("write generated root fixture");
}

fn main() {
    let directory = env::args_os()
        .nth(1)
        .map(PathBuf::from)
        .expect("fixture output directory argument");
    fs::create_dir_all(&directory).expect("create fixture directory");

    let key1 = KeyPair::generate_ecdsa_p256().expect("generate root key 1");
    let key2 = KeyPair::generate_ecdsa_p256().expect("generate root key 2");
    let key3 = KeyPair::generate_ecdsa_p256().expect("generate root key 3");
    let (id1, entry1) = key_entry(&key1);
    let (id2, entry2) = key_entry(&key2);
    let (id3, entry3) = key_entry(&key3);

    let root1_signed = root_signed(1, &id1, entry1);
    let root1 = envelope(
        root1_signed.clone(),
        vec![signature(&root1_signed, &id1, &key1)],
    );

    let root2_signed = root_signed(2, &id2, entry2);
    let root2 = envelope(
        root2_signed.clone(),
        vec![
            signature(&root2_signed, &id1, &key1),
            signature(&root2_signed, &id2, &key2),
        ],
    );

    let root3_signed = root_signed(3, &id3, entry3);
    let root3 = envelope(
        root3_signed.clone(),
        vec![
            signature(&root3_signed, &id2, &key2),
            signature(&root3_signed, &id3, &key3),
        ],
    );

    write_fixture(&directory, "root1.json", &root1);
    write_fixture(&directory, "root2.json", &root2);
    write_fixture(&directory, "root3.json", &root3);
}
