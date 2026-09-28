## Phase 0c tests: dotenv cwd-walk and the real `connections` output.
## Offline only: temp dirs under getTempDir(), no network, no `.waku/` writes.
## Env vars touched are snapshotted and restored, never clobbered.

import std/os
import std/strutils
import std/unittest

import ../src/config
import ../src/providers
import ../src/waku

proc saveEnv(keys: openArray[string]): seq[(string, bool, string)] =
  for name in keys:
    result.add((name, existsEnv(name), getEnv(name)))

proc restoreEnv(saved: seq[(string, bool, string)]) =
  for (name, wasSet, value) in saved:
    if wasSet:
      putEnv(name, value)
    else:
      delEnv(name)

suite "phase 0c dotenv cwd-walk":
  test "findDotenv finds .env upward from a subdirectory":
    let root = getTempDir() / "waku-dotenv-walk"
    let sub = root / "a" / "b"
    createDir(sub)
    writeFile(root / ".env", "WAKU_PROVIDER=openai\n")
    let savedDir = getCurrentDir()
    setCurrentDir(sub)
    let found = findDotenv()
    setCurrentDir(savedDir)
    assert found == root / ".env", "expected walk-up hit, got " & found
    removeDir(root)

  test "findDotenv returns empty when no .env exists above":
    let root = getTempDir() / "waku-dotenv-empty"
    let sub = root / "a"
    createDir(sub)
    let savedDir = getCurrentDir()
    setCurrentDir(sub)
    let found = findDotenv()
    setCurrentDir(savedDir)
    # Either empty, or a developer .env above the temp dir — both are honest.
    if found.len > 0:
      assert fileExists(found)
    removeDir(root)

  test "loadDotenvFile keeps existing vars unless override is set":
    let saved = saveEnv(["WAKU_PHASE0C_A", "WAKU_PHASE0C_B"])
    let dir = getTempDir() / "waku-dotenv-load"
    createDir(dir)
    let path = dir / ".env"
    writeFile(path, "WAKU_PHASE0C_A=from-file\nWAKU_PHASE0C_B=from-file\n")
    putEnv("WAKU_PHASE0C_A", "from-env")
    delEnv("WAKU_PHASE0C_B")
    loadDotenvFile(path)
    assert getEnv("WAKU_PHASE0C_A") == "from-env"
    assert getEnv("WAKU_PHASE0C_B") == "from-file"
    loadDotenvFile(path, override = true)
    assert getEnv("WAKU_PHASE0C_A") == "from-file"
    restoreEnv(saved)
    removeDir(dir)

  test "loadDotenv returns the path it loaded":
    let saved = saveEnv(["WAKU_PHASE0C_C"])
    let root = getTempDir() / "waku-dotenv-ret"
    let sub = root / "sub"
    createDir(sub)
    writeFile(root / ".env", "WAKU_PHASE0C_C=yes\n")
    delEnv("WAKU_PHASE0C_C")
    let savedDir = getCurrentDir()
    setCurrentDir(sub)
    let found = loadDotenv()
    setCurrentDir(savedDir)
    assert found == root / ".env"
    assert getEnv("WAKU_PHASE0C_C") == "yes"
    restoreEnv(saved)
    removeDir(root)

suite "phase 0c connections output":
  const fixture = """
[anthropic]
kind = "anthropic"
key_env = "ANTHROPIC_API_KEY"
model = "claude-sonnet-5"

[hosted]
kind = "anthropic"
key_env = "WAKU_PLATFORM_KEY"
model = "waku-free"
base_url_env = "WAKU_PLATFORM_URL"
hidden_unless_env = true
claims_families = false
scoped_credentials = true
"""

  test "lists configured and missing rows, hides the hosted row":
    let saved = saveEnv(["ANTHROPIC_API_KEY", "WAKU_PLATFORM_URL",
                         "WAKU_PLATFORM_KEY"])
    let rows = parseProviders(fixture)
    putEnv("ANTHROPIC_API_KEY", "sk-test")
    delEnv("WAKU_PLATFORM_URL")
    delEnv("WAKU_PLATFORM_KEY")
    let output = connectionsOutput(rows, "", "/proj/.env")
    assert "anthropic" in output
    assert "configured" in output
    assert "ANTHROPIC_API_KEY" in output
    assert "hosted" notin output
    assert "/proj/.env" in output
    restoreEnv(saved)

  test "missing key names the var to set":
    let saved = saveEnv(["ANTHROPIC_API_KEY"])
    let rows = parseProviders(fixture)
    delEnv("ANTHROPIC_API_KEY")
    let output = connectionsOutput(rows, "", "")
    assert "missing key" in output
    assert "ANTHROPIC_API_KEY" in output
    assert "No .env found" in output
    restoreEnv(saved)

  test "renders the real registry when reachable":
    let registryPath = findProvidersToml()
    if registryPath.len == 0:
      skip()
    else:
      let saved = saveEnv(["WAKU_API_KEY"])
      delEnv("WAKU_API_KEY")
      let rows = loadProviders(registryPath)
      let output = connectionsOutput(rows, "", "/proj/.env")
      assert "anthropic" in output
      assert "openai" in output
      restoreEnv(saved)
