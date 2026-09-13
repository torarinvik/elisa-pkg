#!/usr/bin/env python3
"""Exercise secure aggregate builds for transitive local library dependencies."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "build" / "elisapkg"
BUILD_ROOT = ROOT / "build"
CI_ENABLED = os.environ.get("CI", "").strip().lower() in {"1", "true", "yes"}
REQUIRE_SANDBOX = os.environ.get("ELISAPKG_REQUIRE_SANDBOX_TESTS") == "1" or CI_ENABLED


def write_manifest(path: Path, name: str, targets: list[dict], dependencies: dict) -> None:
    path.write_text(json.dumps({
        "schema-version": 1,
        "package": {"name": name, "version": "1.0.0"},
        "targets": targets,
        "dependencies": dependencies,
    }) + "\n", encoding="utf-8")


def cli(root: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(BIN), *arguments], cwd=root, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        timeout=180, check=False,
    )


def require(status: subprocess.CompletedProcess[str], code: int, label: str) -> None:
    if status.returncode != code:
        raise SystemExit(
            f"{label}: expected exit {code}, got {status.returncode}\n{status.stdout}"
        )


def main() -> int:
    if not BIN.is_file():
        raise SystemExit(f"error: build elisapkg before running this regression: {BIN}")
    compiler_root = os.environ.get("ELISA_COMPILER_ROOT")
    if not compiler_root:
        raise SystemExit("error: set ELISA_COMPILER_ROOT to an Elisa compiler checkout")

    BUILD_ROOT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="elisapkg local graph ", dir=BUILD_ROOT) as raw:
        root = Path(raw)
        bridge = root / "deps" / "bridge lib"
        leaf = root / "deps" / "leaf lib"
        (root / "src").mkdir(parents=True)
        (bridge / "src").mkdir(parents=True)
        (leaf / "src").mkdir(parents=True)

        write_manifest(
            root / "elisapkg.json", "root-app",
            [{"name": "root-app", "kind": "bin", "entry": "src/main.elisa"}],
            {"bridge": {"path": "deps/bridge lib"}},
        )
        write_manifest(
            bridge / "elisapkg.json", "bridge",
            [{"name": "bridge", "kind": "lib", "entry": "src/main.elisa"}],
            {"leaf": {"path": "../leaf lib"}},
        )
        write_manifest(
            leaf / "elisapkg.json", "leaf",
            [{"name": "leaf", "kind": "lib", "entry": "src/main.elisa"}],
            {},
        )
        (leaf / "src" / "main.elisa").write_text(
            "module Leaf:\n"
            "    public:\n"
            "        def answer() -> i64:\n"
            "            return 42\n",
            encoding="utf-8",
        )
        (bridge / "src" / "main.elisa").write_text(
            "module Bridge:\n"
            "    public:\n"
            "        def answer() -> i64:\n"
            "            return Leaf::answer()\n",
            encoding="utf-8",
        )
        (root / "src" / "main.elisa").write_text(
            "def main() -> i64:\n"
            "    return 1 if Bridge::answer() != 42\n"
            "    return 0\n",
            encoding="utf-8",
        )

        require(cli(root, "resolve"), 0, "resolve transitive local graph")
        resolved_lock = json.loads((root / "elisapkg.lock").read_text(encoding="utf-8"))
        package_names = [record["name"] for record in resolved_lock["packages"]]
        if package_names != sorted(package_names) or package_names != ["bridge", "leaf"]:
            raise SystemExit(f"local lock package records are not canonical: {package_names}")
        build = cli(root, "build", "--frozen")
        build_skipped = False
        if build.returncode != 0:
            denied = (
                "sandbox_apply: Operation not permitted" in build.stdout
                or "builds require the macOS Seatbelt sandbox" in build.stdout
            )
            xcode_license_unaccepted = "You have not agreed to the Xcode license agreements" in build.stdout
            if denied or (xcode_license_unaccepted and not REQUIRE_SANDBOX):
                reason = "host denied Seatbelt" if denied else "host Xcode license is not accepted"
                print(f"local dependency build regression skipped: {reason}")
                build_skipped = True
            else:
                raise SystemExit(
                    f"build transitive local graph failed with exit {build.returncode}:\n{build.stdout}"
                )
        else:
            artifact = root / ".elisapkg" / "build" / "root-app"
            if not artifact.is_file():
                raise SystemExit("transitive local build did not produce its binary")
            executed = subprocess.run([str(artifact)], timeout=20, check=False)
            require(executed, 0, "run binary using transitive libraries")

        lock_path = root / "elisapkg.lock"
        valid_lock = lock_path.read_bytes()
        lock_path.write_text("{}\n", encoding="utf-8")
        malformed = cli(root, "build", "--frozen")
        require(malformed, 3, "reject malformed frozen lock")
        lock_path.write_bytes(valid_lock)

        marker = b'"source-digest":"sha256:'
        marker_start = valid_lock.find(marker)
        if marker_start < 0:
            raise SystemExit("local lock fixture lacks a source digest")
        digest_offset = marker_start + len(marker)
        tampered_lock = bytearray(valid_lock)
        tampered_lock[digest_offset] = ord("0") if tampered_lock[digest_offset] != ord("0") else ord("1")
        lock_path.write_bytes(tampered_lock)
        tampered = cli(root, "build", "--frozen")
        require(tampered, 3, "reject validly shaped but incorrect local lock identity")
        lock_path.write_bytes(valid_lock)

        write_manifest(
            leaf / "elisapkg.json", "leaf",
            [{"name": "leaf-tool", "kind": "bin", "entry": "src/main.elisa"}],
            {},
        )
        require(cli(root, "resolve"), 0, "resolve dependency without a library target")
        missing = cli(root, "build", "--frozen")
        require(missing, 6, "reject dependency without a library target")
        if "library target is invalid" not in missing.stdout:
            raise SystemExit(f"missing library target failed for an unexpected reason:\n{missing.stdout}")

        (leaf / "src" / "extra.elisa").write_text(
            "module LeafExtra:\n"
            "    public:\n"
            "        def answer() -> i64:\n"
            "            return 42\n",
            encoding="utf-8",
        )
        write_manifest(
            leaf / "elisapkg.json", "leaf",
            [
                {"name": "leaf", "kind": "lib", "entry": "src/main.elisa"},
                {"name": "leaf-extra", "kind": "lib", "entry": "src/extra.elisa"},
            ],
            {},
        )
        require(cli(root, "resolve"), 0, "resolve dependency with ambiguous libraries")
        ambiguous = cli(root, "build", "--frozen")
        require(ambiguous, 6, "reject dependency with multiple library targets")
        if "library target is invalid" not in ambiguous.stdout:
            raise SystemExit(f"ambiguous library targets failed unexpectedly:\n{ambiguous.stdout}")

        write_manifest(
            root / "elisapkg.json", "root-app",
            [{"name": "root-app", "kind": "bin", "entry": "src/main.elisa"}],
            {
                "bridge": {"path": "deps/bridge lib"},
                "leaf": {"path": "deps/leaf lib"},
            },
        )
        write_manifest(
            bridge / "elisapkg.json", "bridge",
            [{"name": "bridge", "kind": "lib", "entry": "src/main.elisa"}],
            {"leaf": {"path": "../leaf lib"}},
        )
        write_manifest(
            leaf / "elisapkg.json", "leaf",
            [{"name": "leaf", "kind": "lib", "entry": "src/main.elisa"}],
            {"bridge": {"path": "../bridge lib"}},
        )
        cycle_resolution = cli(root, "resolve")
        if cycle_resolution.returncode == 0:
            cycle = cli(root, "build", "--frozen")
            require(cycle, 6, "reject sibling local dependency cycle")
            if "incomplete graph" not in cycle.stdout:
                raise SystemExit(f"sibling dependency cycle failed unexpectedly:\n{cycle.stdout}")
        else:
            require(cycle_resolution, 3, "reject sibling local dependency cycle")

        # Queue C before B to exercise sorted-index insertion. A first-discovery
        # parent tree also misses cycles formed by cross-edges: B -> D -> C -> B.
        cross_edge_packages = {
            "pkg-b": root / "deps" / "pkg-b",
            "pkg-c": root / "deps" / "pkg-c",
            "pkg-d": root / "deps" / "pkg-d",
        }
        for package_root in cross_edge_packages.values():
            (package_root / "src").mkdir(parents=True, exist_ok=True)
            package_name = package_root.name
            write_manifest(
                package_root / "elisapkg.json", package_name,
                [{"name": package_name, "kind": "lib", "entry": "src/main.elisa"}],
                {},
            )
            (package_root / "src" / "main.elisa").write_text(
                f"module {package_name.replace('-', '_').title().replace('_', '')}:\n"
                "    public:\n"
                "        def answer() -> i64:\n"
                "            return 42\n",
                encoding="utf-8",
            )
        write_manifest(
            cross_edge_packages["pkg-b"] / "elisapkg.json", "pkg-b",
            [{"name": "pkg-b", "kind": "lib", "entry": "src/main.elisa"}],
            {"pkg-d": {"path": "../pkg-d"}},
        )
        write_manifest(
            cross_edge_packages["pkg-d"] / "elisapkg.json", "pkg-d",
            [{"name": "pkg-d", "kind": "lib", "entry": "src/main.elisa"}],
            {"pkg-c": {"path": "../pkg-c"}},
        )
        write_manifest(
            cross_edge_packages["pkg-c"] / "elisapkg.json", "pkg-c",
            [{"name": "pkg-c", "kind": "lib", "entry": "src/main.elisa"}],
            {"pkg-b": {"path": "../pkg-b"}},
        )
        write_manifest(
            root / "elisapkg.json", "root-app",
            [{"name": "root-app", "kind": "bin", "entry": "src/main.elisa"}],
            {
                "pkg-c": {"path": "deps/pkg-c"},
                "pkg-b": {"path": "deps/pkg-b"},
            },
        )
        write_manifest(
            cross_edge_packages["pkg-c"] / "elisapkg.json", "pkg-c",
            [{"name": "pkg-c", "kind": "lib", "entry": "src/main.elisa"}],
            {},
        )
        require(cli(root, "resolve"), 0, "resolve acyclic cross-edge local graph")
        write_manifest(
            cross_edge_packages["pkg-c"] / "elisapkg.json", "pkg-c",
            [{"name": "pkg-c", "kind": "lib", "entry": "src/main.elisa"}],
            {"pkg-b": {"path": "../pkg-b"}},
        )
        cross_edge_cycle = cli(root, "resolve")
        require(cross_edge_cycle, 3, "reject cross-edge local dependency cycle")

        if build_skipped and REQUIRE_SANDBOX:
            raise SystemExit("error: local dependency build regression requires Seatbelt")
        if not build_skipped:
            print("transitive local dependency build regression passed")
        else:
            print("local dependency fail-closed checks passed; executable build skipped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
