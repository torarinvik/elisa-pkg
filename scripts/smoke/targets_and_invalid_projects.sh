# Sourced by scripts/test.sh with its smoke fixtures in scope.

# Library targets emit a regular object with the same atomic receipt/cache
# handling as binaries. They must never be accidentally executed or installed
# through the local binary path, and clean must remove the object output too.
LIB_CASE="$TEST_TMP/library-target-$$"
LIB_PREFIX="$LIB_CASE/prefix"
mkdir -p "$LIB_CASE"
"$BIN" init "$LIB_CASE" --lib >/dev/null
(
  cd "$LIB_CASE"
  "$BIN" build >/dev/null
  test -f .elisapkg/build/app.o
  test ! -e .elisapkg/build/app
  "$BIN" build | grep -F '(cached)' >/dev/null
  if "$BIN" run -- >/dev/null 2>&1; then
    echo "library target was executed as a binary" >&2
    exit 1
  else
    test "$?" -eq 6
  fi
  if ELISAPKG_INSTALL_PREFIX="$LIB_PREFIX" "$BIN" install --local >/dev/null 2>&1; then
    echo "library target was installed as a binary" >&2
    exit 1
  else
    test "$?" -eq 7
  fi
  if ELISAPKG_INSTALL_PREFIX="$LIB_PREFIX" "$BIN" install --local unexpected >/dev/null 2>&1; then
    echo "install accepted an unexpected positional argument" >&2
    exit 1
  else
    test "$?" -eq 2
  fi
  "$BIN" clean >/dev/null
  test ! -e .elisapkg/build/app.o
)

# Named targets must have independent artifact names and selectors. Building a
# binary, library, and test from one manifest exercises the same target graph
# without allowing one target's output or run path to shadow another's.
MULTI_CASE="$TEST_TMP/multi-target-$$"
mkdir -p "$MULTI_CASE"
"$BIN" init "$MULTI_CASE" >/dev/null
(
  cd "$MULTI_CASE"
  printf '%s\n' 'def main() -> i64:' '    return 0' > src/tool.elisa
  printf '%s\n' 'def main() -> i64:' '    return 0' > src/util.elisa
  printf '%s\n' 'def main() -> i64:' '    return 0' > src/checks.elisa
  cat > elisapkg.json <<'EOF'
{"schema-version":1,"package":{"name":"multi","version":"0.1.0"},"targets":[{"name":"app","kind":"bin","entry":"src/main.elisa"},{"name":"tool","kind":"bin","entry":"src/tool.elisa"},{"name":"util","kind":"lib","entry":"src/util.elisa"},{"name":"checks","kind":"test","entry":"src/checks.elisa"}],"dependencies":{}}
EOF
  "$BIN" check-manifest >/dev/null
  "$BIN" resolve >/dev/null
  "$BIN" build --bin tool >/dev/null
  test -x .elisapkg/build/tool
  test ! -e .elisapkg/build/app
  "$BIN" build --lib util >/dev/null
  test -f .elisapkg/build/util.o
  "$BIN" test --test checks >/dev/null
  test -x .elisapkg/build/checks
  "$BIN" run --bin tool -- >/dev/null
  if "$BIN" build --bin missing >/dev/null 2>&1; then
    echo "unknown named target was accepted" >&2
    exit 1
  else
    test "$?" -eq 6
  fi
)

# Keep this hostile-path fixture isolated per invocation. A previous interrupted
# run may leave its symlink probes behind, and reusing the directory would make
# the next test fail before exercising the package manager.
BAD="$TEST_TMP/invalid-package-$$"
mkdir -p "$BAD/src"
printf '%s\n' 'def main() -> i64:' '    return 0' > "$BAD/src/main.elisa"
printf '%s\n' '{"schema-version":1,"package":{"name":"Bad_Name","version":"1.0.0"},"targets":[],"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "invalid manifest was accepted" >&2
  exit 1
fi

for invalid_version in 1.01.0 1.0.0-01 1.0; do
  printf '%s\n' "{\"schema-version\":1,\"package\":{\"name\":\"bad\",\"version\":\"$invalid_version\"},\"targets\":[{\"entry\":\"src/main.elisa\"}],\"dependencies\":{}}" > "$BAD/elisapkg.json"
  if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
    echo "invalid version was accepted: $invalid_version" >&2
    exit 1
  fi
done

# A target that exists only through a symlink escaping the package root must be
# rejected before any build or package operation can read it.
OUTSIDE="$TEST_TMP/invalid-target-outside-$$"
mkdir -p "$OUTSIDE"
printf '%s\n' 'def main() -> i64:' '    return 0' > "$OUTSIDE/main.elisa"
ln -s "$OUTSIDE" "$BAD/escape"
printf '%s\n' '{"schema-version":1,"package":{"name":"bad","version":"1.0.0"},"targets":[{"name":"bad","kind":"bin","entry":"escape/main.elisa"}],"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "symlink target escaped the package root" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"bad","version":"1.0.0"},"targets":[{"name":"bad","kind":"bin","entry":"src"}],"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "directory target entry was accepted" >&2
  exit 1
fi
ln -sf src/main.elisa "$BAD/linked-main"
printf '%s\n' '{"schema-version":1,"package":{"name":"bad","version":"1.0.0"},"targets":[{"name":"bad","kind":"bin","entry":"linked-main"}],"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "symlink target entry was accepted" >&2
  exit 1
fi

printf '%s\n' '{"schema-version":1,"targets":[{"name":"target","kind":"bin","entry":"src/main.elisa"}],"package":{"name":"good","version":"1.0.0"},"dependencies":{}}' > "$BAD/elisapkg.json"
(cd "$BAD" && "$BIN" check-manifest >/dev/null)
printf '%s\n' '{"schema-version":1,"package":{"name":"good","version":"1.0.0"},"targets":[{"name":"target","kind":"bin","entry":"src/main.elisa"},{"name":"target","kind":"test","entry":"src/main.elisa"}],"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "duplicate target name was accepted" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"good","version":"1.0.0"},"targets":[{"name":"target","kind":"plugin","entry":"src/main.elisa"}],"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "unsupported target kind was accepted" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"good","version":"1.0.0"},"targets":[{"name":"target","kind":"bin","entry":"src/main.elisa"},1],"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "scalar target array member was accepted" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"good","version":"1.0.0"},"targets":[{"name":"target","kind":"bin","entry":"src/main.elisa"}],"dependencies":{"foo":{"version":"^1.0.0","registry":"primary"}}}' > "$BAD/elisapkg.json"
if ! (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "supported primary registry dependency was rejected" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"good","version":"1.0.0"},"targets":[{"name":"target","kind":"bin","entry":"src/main.elisa"}],"dependencies":{"foo":{"version":"1.01.0","registry":"primary"}}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "invalid dependency requirement was accepted" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"good","version":"1.0.0"},"targets":[{"name":"target","kind":"bin","entry":"src/main.elisa"}],"dependencies":{"foo":{"path":"local","registry":"primary","version":"^1.0.0"}}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "dependency with contradictory sources was accepted" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"good","version":"1.0.0"},"targets":[{"name":"target","kind":"bin","entry":"src/main.elisa"}],"dependencies":{"foo":{"version":"^1.0.0","registry":true}}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "non-string registry was accepted" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"good","version":"1.0.0"},"targets":[{"name":"target","kind":"bin","entry":"src/main.elisa"}],"dependencies":{"foo":{"path":"local","extra":true}}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "unknown local dependency field was accepted" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"good","version":"1.0.0"},"targets":[{"name":"target","kind":"bin","entry":"src/main.elisa"}],"dependencies":{"foo":{"version":"^1.0.0","registry":"primary","extra":true}}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "unknown registry dependency field was accepted" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"good","version":"1.0.0"},"targets":[{"name":"target","kind":"bin","entry":"src/main.elisa"}],"dependencies":{"foo":{"git":"https://example.invalid/foo","rev":"0123456789abcdef0123456789abcdef01234567"}}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "unsupported Git dependency was accepted" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"good","version":"1.0.0"},"targets":[{"name":"target","kind":"bin","entry":"src/main.elisa"}],"dependencies":{"foo":{"version":"^1.0.0","registry":"primary"},"foo":{"version":"^1.0.0","registry":"primary"}}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "duplicate dependency alias was accepted" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"good","version":"1.0.0"},"targets":[{"name":"target","kind":"bin","entry":"../outside.elisa"}],"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "traversal target entry was accepted" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"good","version":"1.0.0"},"targets":[{"name":"target","kind":"bin","entry":"./src/main.elisa"}],"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "dot-prefixed target entry was accepted" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"good","version":"1.0.0"},"targets":[{"name":"target","kind":"bin","entry":"src/main.elisa"}],"dependencies":{}}' > "$BAD/elisapkg.json"
cp "$BAD/elisapkg.json" "$BAD/manifest.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "ambiguous manifest pair was accepted" >&2
  exit 1
fi
mv "$BAD/manifest.json" "$BAD/manifest.json.checked"

printf '%s\n' '{"schema-version":1,"targets":[{"package":{"name":"nested","version":"1.0.0"},"entry":"src/main.elisa"}],"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "nested package object was accepted as the root package" >&2
  exit 1
fi

printf '%s\n' '{"schema-version":1,"package":{"name":"good","name":"evil","version":"1.0.0"},"targets":[{"name":"target","kind":"bin","entry":"src/main.elisa"}],"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "duplicate package key was accepted" >&2
  exit 1
fi

printf '%s\n' '{"schema-version":1,"package":{"name":"good","version":"1.0.0"},"targets":[{"name":"target","kind":"bin","entry":"src/main.elisa","entry":"src/main.elisa"}],"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "duplicate target key was accepted" >&2
  exit 1
fi

printf '%s\n' '{"schema-version":1,"package":{"name":"bad","version":"1.0.0","unknown-policy-hook":true},"targets":[{"entry":"src/main.elisa"}],"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "unknown manifest field was accepted" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"bad","version":"1.0.0","description":true},"targets":[{"entry":"src/main.elisa"}],"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "non-string package metadata was accepted" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"bad","version":"1.0.0"},"targets":[{"name":"bad","kind":"bin","entry":"src/main.elisa"}],"include":{},"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "non-array include field was accepted" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"bad","version":"1.0.0"},"targets":[{"name":"bad","kind":"bin","entry":"src/main.elisa"}],"include":["src/**",],"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "trailing include comma was accepted" >&2
  exit 1
fi
printf '%s\n' '{"schema-version":1,"package":{"name":"bad","version":"1.0.0"},"targets":[{"name":"bad","kind":"bin","entry":"src/main.elisa"}],"include":["src/../secret"],"dependencies":{}}' > "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "unsafe include path was accepted" >&2
  exit 1
fi
python3 - "$BAD/elisapkg.json" <<'PY'
import sys
path = sys.argv[1]
data = b'{"schema-version":1,"package":{"name":"bad","version":"1.0.0","description":"ok\xc0"},"targets":[{"name":"bad","kind":"bin","entry":"src/main.elisa"}],"dependencies":{}}\n'
with open(path, "wb") as handle:
    handle.write(data)
PY
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "invalid UTF-8 manifest was accepted" >&2
  exit 1
fi

printf '%s' '{"schema-version":1,"package":{"name":"bad","version":"1.0.0"},"targets":[{"entry":"src/main.elisa"}],"dependencies":{}}' > "$BAD/elisapkg.json"
head -c 1049000 /dev/zero | tr '\0' ' ' >> "$BAD/elisapkg.json"
if (cd "$BAD" && "$BIN" check-manifest >/dev/null 2>&1); then
  echo "oversized manifest was accepted" >&2
  exit 1
fi

CYCLE="$TEST_TMP/cycle-package-$$"
mkdir -p "$CYCLE/a/src" "$CYCLE/b/src" "$CYCLE/src"
printf '%s\n' 'def main() -> i64:' '    return 0' > "$CYCLE/src/main.elisa"
cp "$CYCLE/src/main.elisa" "$CYCLE/a/src/main.elisa"
cp "$CYCLE/src/main.elisa" "$CYCLE/b/src/main.elisa"
printf '%s\n' '{"schema-version":1,"package":{"name":"a","version":"1.0.0"},"targets":[{"name":"a","kind":"lib","entry":"src/main.elisa"}],"dependencies":{"b":{"path":"../b"}}}' > "$CYCLE/a/elisapkg.json"
printf '%s\n' '{"schema-version":1,"package":{"name":"b","version":"1.0.0"},"targets":[{"name":"b","kind":"lib","entry":"src/main.elisa"}],"dependencies":{"a":{"path":"../a"}}}' > "$CYCLE/b/elisapkg.json"
printf '%s\n' '{"schema-version":1,"package":{"name":"root","version":"1.0.0"},"targets":[{"name":"root","kind":"bin","entry":"src/main.elisa"}],"dependencies":{"a":{"path":"a"}}}' > "$CYCLE/elisapkg.json"
if (cd "$CYCLE" && "$BIN" resolve >/dev/null 2>&1); then
  echo "dependency cycle was accepted" >&2
  exit 1
else
  test "$?" -eq 3
fi
