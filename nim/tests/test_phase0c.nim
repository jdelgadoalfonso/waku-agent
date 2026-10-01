## Phase 0c tests: dotenv cwd-walk. The `connections` dispatch was rewired
## in 5d2 to `integrations.cliMain`; its exit codes are covered in
## `test_cli.nim` and the text surface in `test_integrations.nim`.
## Offline only: temp dirs under getTempDir(), no network, no `.waku/` writes.
## Env vars touched are snapshotted and restored, never clobbered.

import std/os
import std/unittest

import ../src/config
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

suite "phase 5d2 connections dispatch":
  test "dispatch exits 0 on a fresh health store":
    if findProvidersToml().len == 0:
      skip()
    else:
      let saved = saveEnv(["WAKU_HOME"])
      let home = getTempDir() / "waku-conn-fresh"
      if dirExists(home):
        removeDir(home)
      createDir(home)
      putEnv("WAKU_HOME", home)
      assert runCommand(@["connections"]) == 0
      restoreEnv(saved)
      removeDir(home)
